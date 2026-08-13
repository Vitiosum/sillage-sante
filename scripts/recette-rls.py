#!/usr/bin/env python3
"""
Recette RLS : interroge PostgREST sous chaque identite et compare ce que
chacune voit reellement a ce que le README annonce.

    ./scripts/sessions-mfa.py     # prealable : ouvre les sessions
    ./scripts/recette-rls.py

Pourquoi ce script existe
-------------------------
Les 55 policies de ce projet n'ont de sens que sous une vraie identite. Tout
ce qui se teste en `postgres` ou en `anon` ne prouve rien : `postgres` porte
BYPASSRLS, et `anon` ne declenche aucune policy nominative.

C'est aussi et surtout le **test de recette de la migration** : on le rejoue
tel quel sur la cible Clever Cloud. Si la matrice est identique, la reprise
est fidele. Si une case change, on sait exactement laquelle.

Sortie : une matrice ressource x identite, avec le nombre de lignes visibles
ou le code d'erreur PostgREST, puis les ecarts par rapport a l'attendu.
"""
import json
import pathlib
import sys
import urllib.error
import urllib.request

RACINE = pathlib.Path(__file__).resolve().parent.parent
ENVF = RACINE / ".env.local"
SESSIONS = RACINE / ".sessions.local.json"

# Ressources du schema medical, plus deux objets du schema public.
RESSOURCES = [
    ("medical", "cabinets"),
    ("medical", "profils"),
    ("medical", "praticiens"),
    ("medical", "patients"),
    ("medical", "prises_en_charge"),
    ("medical", "rendez_vous"),
    ("medical", "consultations"),
    ("medical", "ordonnances"),
    ("medical", "documents"),
    ("medical", "conversations"),
    ("medical", "messages"),
    ("medical", "notifications"),
    ("medical", "consentements"),
    ("public", "mon_agenda"),
]

# Ce que le README annonce. 'None' = pas d'attendu ferme, on observe.
# cle : (ressource, identite) -> nombre de lignes attendu
ATTENDU = {
    ("rendez_vous", "praticien"): 3,
    ("rendez_vous", "patient"): 3,
    ("consultations", "praticien"): 1,
    ("patients", "praticien"): 1,
    # Le README annonce un role secretariat qui voit l'agenda et l'identite
    # des patients du cabinet, mais jamais le contenu medical.
    ("rendez_vous", "secretariat"): 3,
    ("patients", "secretariat"): 1,
    ("consultations", "secretariat"): 0,
    # anon ne doit jamais rien voir.
    ("rendez_vous", "anon"): 0,
    ("patients", "anon"): 0,
    ("consultations", "anon"): 0,
}


def lire_env():
    env = {}
    for ligne in ENVF.read_text().splitlines():
        if ligne.startswith("#") or "=" not in ligne:
            continue
        k, _, v = ligne.partition("=")
        env[k.strip()] = v.strip()
    return env


def interroger(base, anon, jeton, schema, table):
    """Renvoie un nombre de lignes, ou 'ERR <code>' / 'HTTP <code>'."""
    url = f"{base}/rest/v1/{table}?select=*&limit=1000"
    req = urllib.request.Request(url)
    req.add_header("apikey", anon)
    req.add_header("Authorization", f"Bearer {jeton}")
    req.add_header("Accept-Profile", schema)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return len(json.loads(r.read() or b"[]"))
    except urllib.error.HTTPError as e:
        try:
            d = json.loads(e.read() or b"{}")
            return f"ERR {d.get('code', e.code)}"
        except json.JSONDecodeError:
            return f"HTTP {e.code}"
    except Exception as exc:                                  # noqa: BLE001
        return f"KO {type(exc).__name__}"


def claim(jeton, nom):
    import base64
    try:
        charge = jeton.split(".")[1]
        charge += "=" * (-len(charge) % 4)
        return json.loads(base64.urlsafe_b64decode(charge)).get(nom, "-")
    except Exception:                                          # noqa: BLE001
        return "-"


def main():
    if not SESSIONS.exists():
        raise SystemExit("Absent : .sessions.local.json — lancer d'abord ./scripts/sessions-mfa.py")

    env = lire_env()
    base = env["NEXT_PUBLIC_SUPABASE_URL"].rstrip("/")
    anon = env["NEXT_PUBLIC_SUPABASE_ANON_KEY"]
    sessions = json.loads(SESSIONS.read_text())

    identites = [("anon", anon)]
    for email, s in sessions.items():
        identites.append((s["role_metier"], s["access_token"]))

    print("Identites")
    for nom, jeton in identites:
        if nom == "anon":
            print(f"  {nom:14} cle publishable, aucune session")
        else:
            app = claim(jeton, "app_metadata") or {}
            print(f"  {nom:14} aal={claim(jeton, 'aal'):5} "
                  f"praticien_id={'oui' if app.get('praticien_id') else 'non':3} "
                  f"patient_id={'oui' if app.get('patient_id') else 'non'}")

    largeur = max(len(t) for _, t in RESSOURCES) + 2
    entete = "".ljust(largeur) + "".join(n.ljust(14) for n, _ in identites)
    print("\n" + entete)
    print("-" * len(entete))

    resultats = {}
    for schema, table in RESSOURCES:
        ligne = table.ljust(largeur)
        for nom, jeton in identites:
            v = interroger(base, anon, jeton, schema, table)
            resultats[(table, nom)] = v
            ligne += str(v).ljust(14)
        print(ligne)

    print("\nEcarts par rapport a ce que le README annonce")
    ecarts = 0
    for (table, ident), attendu in sorted(ATTENDU.items()):
        obtenu = resultats.get((table, ident), "absent")
        if obtenu != attendu:
            ecarts += 1
            print(f"  {table}.{ident:14} attendu={attendu}  obtenu={obtenu}")
    if ecarts == 0:
        print("  aucun")
    else:
        print(f"\n  {ecarts} ecart(s). Voir CONSTATS-DEPLOIEMENT.md.")

    print("\nRejouer ce script apres migration : une matrice identique = reprise fidele.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
