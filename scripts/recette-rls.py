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

# Attendus exprimes en ISOLATION, pas en valeurs absolues : le corpus varie
# selon qu'on a charge le volume ou non, mais les regles d'acces, elles, ne
# changent pas. C'est ce qui rend ce harnais rejouable tel quel sur la cible.
#
#   0        -> la ressource doit etre invisible
#   ">0"     -> au moins une ligne doit etre visible
#   "=anon"  -> doit voir exactement ce que voit un anonyme (aucun privilege)
ATTENDU = {
    # anon : rien du dossier medical. Trois tables sont volontairement
    # publiques (annuaire), elles ne figurent pas ici.
    ("patients", "anon"): 0,
    ("prises_en_charge", "anon"): 0,
    ("rendez_vous", "anon"): 0,
    ("consultations", "anon"): 0,
    ("documents", "anon"): 0,
    ("messages", "anon"): 0,
    # patient : son propre dossier.
    ("patients", "patient"): ">0",
    ("rendez_vous", "patient"): ">0",
    ("consultations", "patient"): ">0",
    # praticien en aal2 : les patients qu'il prend en charge.
    ("patients", "praticien"): ">0",
    ("rendez_vous", "praticien"): ">0",
    ("consultations", "praticien"): ">0",
    # Le README annonce un secretariat qui voit l'agenda et l'identite des
    # patients du cabinet, mais jamais le contenu medical.
    ("rendez_vous", "secretariat"): ">0",
    ("patients", "secretariat"): ">0",
    ("consultations", "secretariat"): 0,
}


def conforme(obtenu, attendu):
    if attendu == ">0":
        return isinstance(obtenu, int) and obtenu > 0
    return obtenu == attendu


def lire_env():
    env = {}
    for ligne in ENVF.read_text().splitlines():
        if ligne.startswith("#") or "=" not in ligne:
            continue
        k, _, v = ligne.partition("=")
        env[k.strip()] = v.strip()
    return env


def interroger(base, anon, jeton, schema, table):
    """Renvoie le nombre EXACT de lignes visibles, ou 'ERR <code>'.

    On demande `count=exact` avec une plage vide plutot que de compter les
    lignes ramenees : sans ca, toute table depassant la limite renverrait le
    plafond et non la verite. C'est ce qui faisait afficher 1000 rendez-vous
    la ou il y en a 20 003.
    """
    url = f"{base}/rest/v1/{table}?select=*"
    req = urllib.request.Request(url)
    req.add_header("apikey", anon)
    req.add_header("Authorization", f"Bearer {jeton}")
    req.add_header("Accept-Profile", schema)
    req.add_header("Prefer", "count=exact")
    req.add_header("Range-Unit", "items")
    req.add_header("Range", "0-0")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            plage = r.headers.get("Content-Range", "")
            total = plage.split("/")[-1] if "/" in plage else ""
            return int(total) if total.isdigit() else len(json.loads(r.read() or b"[]"))
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


def rafraichir(base, anon, sessions):
    """Renouvelle les jetons expires.

    jwt_expiry vaut 3600 s : un harnais de recette rejoue des mois plus tard
    tomberait sinon en PGRST303 sur toutes les lignes, ce qui ressemble a une
    regression alors que ce n'est qu'un jeton perime. Le refresh preserve le
    niveau aal, donc le praticien reste en aal2 sans repasser par le TOTP.
    """
    import time
    change = False
    for email, s in sessions.items():
        exp = claim(s["access_token"], "exp")
        if isinstance(exp, int) and exp > time.time() + 60:
            continue
        if not s.get("refresh_token"):
            print(f"  {email} : jeton expire et pas de refresh_token — relancer ./scripts/sessions-mfa.py")
            continue
        req = urllib.request.Request(
            f"{base}/auth/v1/token?grant_type=refresh_token",
            data=json.dumps({"refresh_token": s["refresh_token"]}).encode(), method="POST")
        req.add_header("apikey", anon)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                d = json.loads(r.read())
            s["access_token"] = d["access_token"]
            s["refresh_token"] = d.get("refresh_token", s["refresh_token"])
            change = True
            print(f"  {email:28} jeton renouvele (aal={claim(s['access_token'], 'aal')})")
        except urllib.error.HTTPError as e:
            print(f"  {email} : refresh refuse ({e.code}) — relancer ./scripts/sessions-mfa.py")
    if change:
        SESSIONS.write_text(json.dumps(sessions, indent=1))
    return sessions


def main():
    if not SESSIONS.exists():
        raise SystemExit("Absent : .sessions.local.json — lancer d'abord ./scripts/sessions-mfa.py")

    env = lire_env()
    base = env["NEXT_PUBLIC_SUPABASE_URL"].rstrip("/")
    anon = env["NEXT_PUBLIC_SUPABASE_ANON_KEY"]
    sessions = json.loads(SESSIONS.read_text())
    sessions = rafraichir(base, anon, sessions)

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
        if not conforme(obtenu, attendu):
            ecarts += 1
            print(f"  {table}.{ident:14} attendu={attendu}  obtenu={obtenu}")
    if ecarts == 0:
        print("  aucun")
    else:
        print(f"\n  {ecarts} ecart(s). Voir CONSTATS-DEPLOIEMENT.md.")

    print("\nRejouer ce script apres migration : une matrice identique = reprise fidele.")
    # Code de sortie exploitable en CI : 1 des qu'un ecart existe. Sans ca,
    # « recette verte » ne voulait rien dire.
    return 1 if ecarts else 0


if __name__ == "__main__":
    sys.exit(main())
