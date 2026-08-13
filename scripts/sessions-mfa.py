#!/usr/bin/env python3
"""
Ouvre de vraies sessions GoTrue pour les comptes de demonstration, et enrole
un facteur TOTP sur le praticien.

    ./scripts/sessions-mfa.py

Pourquoi c'est necessaire :

  - auth.sessions, auth.refresh_tokens et auth.mfa_factors restent vides si
    personne ne se connecte. dump_auth.sql ne dit alors rien de ce qui se
    passe pour les sessions en cours lors d'une migration d'auth — qui est la
    premiere question posee par un client.

  - medical.mfa_verifiee() lit le claim `aal` du JWT. Les policies de
    medical.consultations l'exigent (20260114090400_rls.sql:132-136). Sans
    facteur TOTP verifie, tout le parcours praticien est inaccessible et on
    ne peut pas tester la RLS sous cette identite.

Aucun mot de passe n'est cree ni manipule : on passe par l'API Admin
(generate_link) puis /verify, ce qui est le chemin prevu pour un magic link.

Les jetons sont ecrits dans .sessions.local.json (ignore par git) pour que
scripts/recette-rls.py les reutilise.
"""
import base64
import hashlib
import hmac
import json
import os
import pathlib
import struct
import time
import urllib.error
import urllib.request

RACINE = pathlib.Path(__file__).resolve().parent.parent
ENVF = RACINE / ".env.local"
SORTIE = RACINE / ".sessions.local.json"

COMPTES = ["patient@example.test", "praticien@example.test", "secretariat@example.test"]


def lire_env():
    if not ENVF.exists():
        raise SystemExit("Absent : .env.local")
    env = {}
    for ligne in ENVF.read_text().splitlines():
        if ligne.startswith("#") or "=" not in ligne:
            continue
        k, _, v = ligne.partition("=")
        env[k.strip()] = v.strip()
    for cle in ("NEXT_PUBLIC_SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "NEXT_PUBLIC_SUPABASE_ANON_KEY"):
        if not env.get(cle):
            raise SystemExit(f"{cle} vide dans .env.local")
    return env


def appel(url, methode="POST", corps=None, entetes=None):
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
    """RFC 6238, SHA-1, pas de 30 s, 6 chiffres. Pas de dependance externe."""
    rembourrage = "=" * (-len(secret_b32) % 8)
    cle = base64.b32decode(secret_b32.upper() + rembourrage)
    compteur = int(time.time()) // 30 + decalage
    empreinte = hmac.new(cle, struct.pack(">Q", compteur), hashlib.sha1).digest()
    dec = empreinte[-1] & 0x0F
    valeur = struct.unpack(">I", empreinte[dec:dec + 4])[0] & 0x7FFFFFFF
    return f"{valeur % 1_000_000:06d}"


def claim_aal(jeton):
    """Lit le claim aal du JWT sans verifier la signature (diagnostic seul)."""
    try:
        charge = jeton.split(".")[1]
        charge += "=" * (-len(charge) % 4)
        return json.loads(base64.urlsafe_b64decode(charge)).get("aal", "?")
    except Exception:
        return "?"


def main():
    env = lire_env()
    base = env["NEXT_PUBLIC_SUPABASE_URL"].rstrip("/")
    sr = env["SUPABASE_SERVICE_ROLE_KEY"]
    anon = env["NEXT_PUBLIC_SUPABASE_ANON_KEY"]

    admin = {"apikey": sr, "Authorization": f"Bearer {sr}"}
    sessions = {}

    for email in COMPTES:
        st, d = appel(f"{base}/auth/v1/admin/generate_link", corps={"type": "magiclink", "email": email}, entetes=admin)
        if st != 200:
            print(f"ERR  generate_link {email}: {st} {json.dumps(d)[:160]}")
            continue

        jeton = d.get("hashed_token")
        if not jeton:
            print(f"ERR  {email}: pas de hashed_token dans la reponse")
            continue

        st, s = appel(f"{base}/auth/v1/verify", corps={"type": "magiclink", "token_hash": jeton},
                      entetes={"apikey": anon})
        if st != 200 or "access_token" not in s:
            print(f"ERR  verify {email}: {st} {json.dumps(s)[:160]}")
            continue

        sessions[email] = {
            "user_id": s["user"]["id"],
            "access_token": s["access_token"],
            "refresh_token": s.get("refresh_token"),
            "role_metier": (s["user"].get("app_metadata") or {}).get("role_metier", "patient"),
        }
        print(f"OK   session {email:28} aal={claim_aal(s['access_token'])} "
              f"role={sessions[email]['role_metier']}")

    # --- MFA TOTP sur le praticien -----------------------------------------
    # Le facteur deja enrole est reutilise : son secret est conserve d'une
    # execution a l'autre. Sans ca, chaque relance empilerait un facteur de
    # plus (config.toml en autorise 3, on les epuiserait vite).
    ancien = {}
    if SORTIE.exists():
        try:
            ancien = json.loads(SORTIE.read_text()).get("praticien@example.test") or {}
        except json.JSONDecodeError:
            ancien = {}

    prat = sessions.get("praticien@example.test")
    if prat:
        porteur = {"apikey": anon, "Authorization": f"Bearer {prat['access_token']}"}
        fid = ancien.get("factor_id")
        secret = ancien.get("totp_secret")

        if fid and secret:
            print(f"OK   facteur TOTP reutilise id={fid}")
            f, st = {}, 200
        else:
            st, f = appel(f"{base}/auth/v1/factors",
                          corps={"factor_type": "totp", "friendly_name": "Demo TOTP"}, entetes=porteur)
            if st in (200, 201):
                fid = f["id"]
                secret = (f.get("totp") or {}).get("secret")
                print(f"OK   facteur TOTP enrole  id={fid}")

        if st not in (200, 201):
            print(f"ERR  enrolement TOTP: {st} {json.dumps(f)[:200]}")
        else:

            st, c = appel(f"{base}/auth/v1/factors/{fid}/challenge", corps={}, entetes=porteur)
            if st != 200:
                print(f"ERR  challenge: {st} {json.dumps(c)[:200]}")
            else:
                # Le pas TOTP fait 30 s : on essaie la fenetre courante puis la precedente.
                for decalage in (0, -1, 1):
                    st, v = appel(f"{base}/auth/v1/factors/{fid}/verify",
                                  corps={"challenge_id": c["id"], "code": code_totp(secret, decalage)},
                                  entetes=porteur)
                    if st == 200 and "access_token" in v:
                        prat["access_token"] = v["access_token"]
                        prat["refresh_token"] = v.get("refresh_token")
                        prat["totp_secret"] = secret
                        prat["factor_id"] = fid
                        print(f"OK   TOTP verifie         aal={claim_aal(v['access_token'])}")
                        break
                else:
                    print(f"ERR  verification TOTP: {st} {json.dumps(v)[:200]}")

    SORTIE.write_text(json.dumps(sessions, indent=1))
    os.chmod(SORTIE, 0o600)
    print(f"\nJetons ecrits dans {SORTIE.name} (ignore par git, permissions 600)")
    print("Suite : ./scripts/recette-rls.py")


if __name__ == "__main__":
    main()
