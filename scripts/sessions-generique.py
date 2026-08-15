#!/usr/bin/env python3
"""
Ouvre de vraies sessions applicatives, et enrole un facteur TOTP si besoin.

    ./sessions.py recette.config.json

Sans sessions reelles, on ne teste rien : les requetes en `postgres` portent
BYPASSRLS et celles en cle anonyme ne declenchent aucune policy nominative.
La RLS ne se verifie que sous une identite qui a vraiment un jeton.

AUCUN MOT DE PASSE n'est cree ni manipule : on passe par l'API Admin
(generate_link) puis /verify, chemin prevu pour un lien magique. Les jetons
sont ecrits dans .sessions.local.json, a ignorer par git.

Le TOTP est calcule ici (RFC 6238, sans dependance) : beaucoup de politiques
exigent aal2, et sans facteur verifie tout le parcours concerne est
inaccessible — ce qui se lit a tort comme « la RLS bloque tout ».
"""
import base64
import hashlib
import hmac
import json
import os
import pathlib
import struct
import sys
import time
import urllib.error
import urllib.request

CONF = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "recette.config.json")
SORTIE = CONF.parent / ".sessions.local.json"


def appel(url, corps=None, entetes=None, methode="POST"):
    donnees = json.dumps(corps).encode() if corps is not None else None
    req = urllib.request.Request(url, data=donnees, method=methode)
    req.add_header("Content-Type", "application/json")
    for k, v in (entetes or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        brut = e.read()
        try:
            return e.code, json.loads(brut or b"{}")
        except json.JSONDecodeError:
            return e.code, {"raw": brut.decode(errors="replace")[:300]}


def code_totp(secret_b32, decalage=0):
    rembourrage = "=" * (-len(secret_b32) % 8)
    cle = base64.b32decode(secret_b32.upper() + rembourrage)
    compteur = int(time.time()) // 30 + decalage
    e = hmac.new(cle, struct.pack(">Q", compteur), hashlib.sha1).digest()
    d = e[-1] & 0x0F
    return f"{(struct.unpack('>I', e[d:d + 4])[0] & 0x7FFFFFFF) % 1_000_000:06d}"


def claim(jeton, nom):
    try:
        c = jeton.split(".")[1]
        c += "=" * (-len(c) % 4)
        return json.loads(base64.urlsafe_b64decode(c)).get(nom, "-")
    except Exception:                                          # noqa: BLE001
        return "-"


def main():
    if not CONF.exists():
        raise SystemExit(f"Absent : {CONF}. Voir recette.config.exemple.json")
    conf = json.loads(CONF.read_text())
    base = conf["url"].rstrip("/")
    anon, sr = conf["cle_anon"], conf["cle_service_role"]
    admin = {"apikey": sr, "Authorization": f"Bearer {sr}"}

    ancien = json.loads(SORTIE.read_text()) if SORTIE.exists() else {}
    sessions = {}

    for compte in conf["comptes"]:
        email, role = compte["email"], compte.get("role", "?")
        st, d = appel(f"{base}/auth/v1/admin/generate_link",
                      {"type": "magiclink", "email": email}, admin)
        if st != 200 or not d.get("hashed_token"):
            print(f"ERR  generate_link {email}: {st} {json.dumps(d)[:140]}")
            continue

        st, s = appel(f"{base}/auth/v1/verify",
                      {"type": "magiclink", "token_hash": d["hashed_token"]}, {"apikey": anon})
        if st != 200 or "access_token" not in s:
            print(f"ERR  verify {email}: {st} {json.dumps(s)[:140]}")
            continue

        sessions[email] = {
            "role": role,
            "user_id": s["user"]["id"],
            "access_token": s["access_token"],
            "refresh_token": s.get("refresh_token"),
        }
        print(f"OK   {email:32} aal={claim(s['access_token'], 'aal')} role={role}")

        if not compte.get("mfa"):
            continue

        # Facteur TOTP. Celui deja enrole est reutilise : sinon chaque relance
        # en empile un de plus et epuise le quota du projet.
        porteur = {"apikey": anon, "Authorization": f"Bearer {sessions[email]['access_token']}"}
        prec = ancien.get(email) or {}
        fid, secret = prec.get("factor_id"), prec.get("totp_secret")

        if not (fid and secret):
            st, f = appel(f"{base}/auth/v1/factors",
                          {"factor_type": "totp", "friendly_name": "recette"}, porteur)
            if st not in (200, 201):
                print(f"     ERR enrolement TOTP: {st} {json.dumps(f)[:140]}")
                continue
            fid, secret = f["id"], (f.get("totp") or {}).get("secret")

        st, c = appel(f"{base}/auth/v1/factors/{fid}/challenge", {}, porteur)
        if st != 200:
            print(f"     ERR challenge: {st} {json.dumps(c)[:140]}")
            continue

        for decalage in (0, -1, 1):          # tolerance a la derive d'horloge
            st, v = appel(f"{base}/auth/v1/factors/{fid}/verify",
                          {"challenge_id": c["id"], "code": code_totp(secret, decalage)}, porteur)
            if st == 200 and "access_token" in v:
                sessions[email].update(access_token=v["access_token"],
                                       refresh_token=v.get("refresh_token", sessions[email]["refresh_token"]),
                                       factor_id=fid, totp_secret=secret)
                print(f"     TOTP verifie -> aal={claim(v['access_token'], 'aal')}")
                break
        else:
            print(f"     ERR verification TOTP: {json.dumps(v)[:140]}")

    SORTIE.write_text(json.dumps(sessions, indent=1))
    os.chmod(SORTIE, 0o600)
    print(f"\n{len(sessions)} session(s) -> {SORTIE.name} (600, a ignorer par git)")


if __name__ == "__main__":
    main()
