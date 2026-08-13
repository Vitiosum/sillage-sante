#!/usr/bin/env python3
"""
Depose des objets dans les quatre buckets, et verifie les URL signees.

    ./scripts/objets-demo.py

Pourquoi : avec 0 objet, la migration du Storage vers Cellar reste theorique.
Or c'est la que se jouent le chiffrement AES navigateur (lib/chiffrement.ts),
les URL signees, et l'upload reprenable TUS.

Le chemin des objets n'est pas libre : les policies de storage.objects
castent le premier segment en uuid
(20260114090600_storage.sql, 20260114091200_storage_avance.sql).
Un chemin qui ne commence pas par un uuid fait echouer la lecture de tout
le bucket — c'est un des constats de CONSTATS-DEPLOIEMENT.md.
"""
import json
import os
import pathlib
import urllib.error
import urllib.request

RACINE = pathlib.Path(__file__).resolve().parent.parent
ENVF = RACINE / ".env.local"


def lire_env():
    env = {}
    for ligne in ENVF.read_text().splitlines():
        if ligne.startswith("#") or "=" not in ligne:
            continue
        k, _, v = ligne.partition("=")
        env[k.strip()] = v.strip()
    return env


def appel(url, methode, corps=None, entetes=None, brut=False):
    req = urllib.request.Request(url, data=corps, method=methode)
    for k, v in (entetes or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            contenu = r.read()
            return r.status, contenu if brut else json.loads(contenu or b"{}")
    except urllib.error.HTTPError as e:
        d = e.read()
        try:
            return e.code, json.loads(d or b"{}")
        except json.JSONDecodeError:
            return e.code, {"raw": d.decode(errors="replace")[:200]}


def main():
    env = lire_env()
    base = env["NEXT_PUBLIC_SUPABASE_URL"].rstrip("/")
    sr = env["SUPABASE_SERVICE_ROLE_KEY"]
    ent = {"apikey": sr, "Authorization": f"Bearer {sr}"}

    # Un uuid de patient reel : les policies castent le 1er segment en uuid.
    import subprocess
    u = subprocess.run(
        ["/opt/homebrew/bin/psql", env["SUPABASE_DB_URL"], "-tAc",
         "select id from medical.patients where nom_naissance not like 'Volume%' limit 1"],
        capture_output=True, text=True, timeout=60)
    patient = u.stdout.strip()
    if not patient:
        raise SystemExit("Aucun patient trouve — jouer d'abord scripts/donnees-demo.sql")

    # Chaque bucket impose sa liste allowed_mime_types : un Content-Type non
    # declare est refuse en 415, meme avec la cle service_role. C'est une
    # contrainte portee par storage.buckets, donc a reproduire sur la cible —
    # Cellar, lui, ne filtre pas les types MIME.
    #   avatars            image/png, image/jpeg, image/webp        2 Mio
    #   documents-medicaux application/pdf, image/*, application/dicom  50 Mio
    #   ordonnances        application/pdf                          5 Mio
    #   imagerie           application/dicom, application/zip, image/png  5 Gio
    objets = [
        ("documents-medicaux", f"{patient}/compte-rendu-2026-08.pdf", "application/pdf", 48 * 1024),
        ("documents-medicaux", f"{patient}/analyse-biologie.pdf", "application/pdf", 32 * 1024),
        ("ordonnances", f"{patient}/ordonnance-2026-08.pdf", "application/pdf", 12 * 1024),
        ("avatars", f"{patient}/portrait.png", "image/png", 64 * 1024),
        ("imagerie", f"{patient}/irm-serie-01.dcm", "application/dicom", 256 * 1024),
    ]

    print("Depots")
    for bucket, chemin, mime, taille in objets:
        # Contenu aleatoire : incompressible, donc les volumetries sont sinceres.
        contenu = os.urandom(taille)
        st, d = appel(f"{base}/storage/v1/object/{bucket}/{chemin}", "POST", contenu,
                      {**ent, "Content-Type": mime, "x-upsert": "true"})
        etat = "OK  " if st in (200, 201) else f"ERR {st}"
        print(f"  {etat} {bucket:20} {len(contenu) // 1024:4} Kio  {chemin.split('/')[-1]}")
        if st not in (200, 201):
            print(f"       {json.dumps(d)[:160]}")

    # URL signee : c'est le mecanisme que la cible devra reproduire sur Cellar.
    bucket, chemin = objets[0][0], objets[0][1]
    st, d = appel(f"{base}/storage/v1/object/sign/{bucket}/{chemin}", "POST",
                  json.dumps({"expiresIn": 60}).encode(),
                  {**ent, "Content-Type": "application/json"})
    print("\nURL signee")
    if st == 200 and d.get("signedURL"):
        st2, contenu = appel(f"{base}/storage/v1{d['signedURL']}", "GET", entetes={}, brut=True)
        print(f"  OK   generee, lecture sans authentification : HTTP {st2}, {len(contenu)} octets")
    else:
        print(f"  ERR  {st} {json.dumps(d)[:160]}")

    print("\nSuite : relever storage.objects et la volumetrie par bucket.")


if __name__ == "__main__":
    main()
