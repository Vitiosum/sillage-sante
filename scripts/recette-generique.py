#!/usr/bin/env python3
"""
Recette des regles d'acces : matrice ressource x identite.

    ./sessions.py recette.config.json      # prealable
    ./recette-rls.py recette.config.json [--json sortie.json]

C'EST LE LIVRABLE QUI PROUVE LA MIGRATION. On le joue sur la source, on le
rejoue sur la cible : matrice identique = reprise fidele. Une case qui change
designe exactement le probleme, sans avoir a relire une policy.

Trois choix le rendent rejouable des mois plus tard, et transposable d'une
plateforme a l'autre :

  1. Il RENOUVELLE les jetons expires avant d'interroger. Les jetons vivent
     une heure : sans ca, toute la matrice tombe en erreur d'authentification
     et ressemble a une regression massive.
  2. Les attendus sont exprimes en ISOLATION (0, >0), pas en valeurs absolues.
     Le corpus varie selon qu'on a charge du volume ou non ; les regles
     d'acces, elles, ne changent pas. C'est ce qui permet de comparer source
     et cible sans reecrire le test.
  3. Il COMPTE COTE SERVEUR (Prefer: count=exact). Compter les lignes ramenees
     afficherait le plafond de pagination au lieu de la verite.
"""
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
CONF = pathlib.Path(ARGS[0] if ARGS else "recette.config.json")
SESSIONS = CONF.parent / ".sessions.local.json"
JSON_OUT = None
if "--json" in sys.argv:
    JSON_OUT = pathlib.Path(sys.argv[sys.argv.index("--json") + 1])


def claim(jeton, nom):
    import base64
    try:
        c = jeton.split(".")[1]
        c += "=" * (-len(c) % 4)
        return json.loads(base64.urlsafe_b64decode(c)).get(nom, "-")
    except Exception:                                          # noqa: BLE001
        return "-"


def rafraichir(base, anon, sessions):
    change = False
    for email, s in sessions.items():
        exp = claim(s["access_token"], "exp")
        if isinstance(exp, int) and exp > time.time() + 60:
            continue
        if not s.get("refresh_token"):
            print(f"  {email} : jeton expire, pas de refresh_token — relancer sessions.py")
            continue
        req = urllib.request.Request(f"{base}/auth/v1/token?grant_type=refresh_token",
                                     data=json.dumps({"refresh_token": s["refresh_token"]}).encode(),
                                     method="POST")
        req.add_header("apikey", anon)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                d = json.loads(r.read())
            s["access_token"] = d["access_token"]
            s["refresh_token"] = d.get("refresh_token", s["refresh_token"])
            change = True
            print(f"  {email:32} jeton renouvele (aal={claim(s['access_token'], 'aal')})")
        except urllib.error.HTTPError as e:
            print(f"  {email} : refresh refuse ({e.code}) — relancer sessions.py")
    if change:
        SESSIONS.write_text(json.dumps(sessions, indent=1))
    return sessions


def compter(base, anon, jeton, schema, ressource):
    """Nombre EXACT de lignes visibles, ou 'ERR <code>'."""
    req = urllib.request.Request(f"{base}/rest/v1/{ressource}?select=*")
    req.add_header("apikey", anon)
    req.add_header("Authorization", f"Bearer {jeton}")
    if schema:
        req.add_header("Accept-Profile", schema)
    req.add_header("Prefer", "count=exact")
    req.add_header("Range-Unit", "items")
    req.add_header("Range", "0-0")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            total = (r.headers.get("Content-Range") or "").split("/")[-1]
            return int(total) if total.isdigit() else 0
    except urllib.error.HTTPError as e:
        try:
            return f"ERR {json.loads(e.read() or b'{}').get('code', e.code)}"
        except json.JSONDecodeError:
            return f"HTTP {e.code}"
    except Exception as exc:                                   # noqa: BLE001
        return f"KO {type(exc).__name__}"


def conforme(obtenu, attendu):
    if attendu == ">0":
        return isinstance(obtenu, int) and obtenu > 0
    if attendu == "*":
        return not isinstance(obtenu, str)
    return obtenu == attendu


def main():
    if not CONF.exists():
        raise SystemExit(f"Absent : {CONF}. Voir recette.config.exemple.json")
    conf = json.loads(CONF.read_text())
    base = conf["url"].rstrip("/")
    anon = conf["cle_anon"]

    if not SESSIONS.exists():
        raise SystemExit(f"Absent : {SESSIONS.name} — lancer d'abord ./sessions.py {CONF.name}")
    sessions = rafraichir(base, anon, json.loads(SESSIONS.read_text()))

    identites = [("anon", anon)] + [(s["role"], s["access_token"]) for s in sessions.values()]

    print("\nIdentites")
    for nom, jeton in identites:
        if nom == "anon":
            print(f"  {nom:14} cle publique, aucune session")
        else:
            print(f"  {nom:14} aal={claim(jeton, 'aal')}")

    ressources = conf["ressources"]
    largeur = max(len(r["nom"]) for r in ressources) + 2
    entete = "".ljust(largeur) + "".join(n.ljust(14) for n, _ in identites)
    print("\n" + entete + "\n" + "-" * len(entete))

    resultats, matrice = {}, {}
    for r in ressources:
        ligne = r["nom"].ljust(largeur)
        matrice[r["nom"]] = {}
        for nom, jeton in identites:
            v = compter(base, anon, jeton, r.get("schema"), r["nom"])
            resultats[(r["nom"], nom)] = v
            matrice[r["nom"]][nom] = v
            ligne += str(v).ljust(14)
        print(ligne)

    print("\nEcarts par rapport aux regles annoncees")
    ecarts = []
    for cle, attendu in sorted((conf.get("attendus") or {}).items()):
        ressource, ident = cle.split("@", 1)
        obtenu = resultats.get((ressource, ident), "absent")
        if not conforme(obtenu, attendu):
            ecarts.append({"ressource": ressource, "identite": ident,
                           "attendu": attendu, "obtenu": obtenu})
            print(f"  {ressource}@{ident:14} attendu={attendu}  obtenu={obtenu}")
    if not ecarts:
        print("  aucun")

    if JSON_OUT:
        JSON_OUT.write_text(json.dumps({"matrice": matrice, "ecarts": ecarts}, indent=1))
        print(f"\nMatrice ecrite dans {JSON_OUT}")
        print("Comparer source et cible :  diff <(jq -S .matrice source.json) <(jq -S .matrice cible.json)")

    print("\nMatrice identique apres migration = reprise fidele.")
    return 1 if ecarts else 0


if __name__ == "__main__":
    sys.exit(main())
