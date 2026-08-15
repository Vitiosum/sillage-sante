#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# L'OUTIL : votre rapport de migration Supabase -> Clever Cloud, personnalise.
#
#   SUPABASE_DB_URL='postgresql://...' ./scripts/analyser-migration.sh
#
# Ce qu'il fait :
#   1. inventorie VOTRE projet (via releve-supabase.sh)         -> releve.json
#   2. croise chaque composant releve avec la correspondance
#      Clever Cloud verifiee                                    -> RAPPORT-MIGRATION.md
#
# Le rapport ne parle que de ce que VOUS utilisez : pas de generalites.
# Il liste ce qui se reprend tel quel, ce qui se demande au support (avec la
# liste exacte des demandes a formuler), et ce qui se reecrit.
#
# Ce qu'il ne fait PAS, volontairement : modifier quoi que ce soit. Un outil
# qui reecrit votre backend a votre place est un outil auquel on ne peut pas
# faire confiance. Celui-ci mesure et explique ; les decisions restent a vous.
#
# Prerequis : psql, python3. Prendre la chaine "Session pooler" (IPv4).
# ---------------------------------------------------------------------------
set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SORTIE_JSON="${1:-releve.json}"
SORTIE_MD="${2:-RAPPORT-MIGRATION.md}"

if [[ -z "${SUPABASE_DB_URL:-}" && ! -f "$SORTIE_JSON" ]]; then
  echo "SUPABASE_DB_URL non definie et aucun $SORTIE_JSON existant." >&2
  echo "Console Supabase > Connect > Session pooler, puis :" >&2
  echo "  SUPABASE_DB_URL='postgresql://...' $0" >&2
  exit 1
fi

if [[ -n "${SUPABASE_DB_URL:-}" ]]; then
  echo "==> Inventaire du projet (lecture seule)"
  "$ICI/releve-supabase.sh" > "$SORTIE_JSON"
fi

echo "==> Rapport personnalise"
python3 - "$SORTIE_JSON" "$SORTIE_MD" <<'PY'
import json, sys, datetime

releve = json.load(open(sys.argv[1]))

# Correspondance verifiee en aout 2026 contre la documentation Clever Cloud.
# Trois statuts : defaut (CREATE EXTENSION suffit), ticket (demande support),
# aucun (a reecrire, avec la piste).
DEFAUT = {"postgis", "postgis_raster", "postgis_topology", "postgis_tiger_geocoder",
          "vector", "pgcrypto", "uuid-ossp", "pg_trgm", "btree_gist", "btree_gin",
          "unaccent", "hstore", "citext", "pg_stat_statements", "hypopg",
          "postgres_fdw", "plv8", "plpgsql", "ltree", "intarray", "cube",
          "earthdistance", "fuzzystrmatch", "dblink", "tablefunc", "pgrowlocks"}
TICKET = {"pg_cron", "pg_net", "pgaudit", "pg_partman", "pg_repack", "pgtap",
          "timescaledb", "rum", "pg_ivm", "pgsql-http"}
REECRIRE = {
    "pgsodium": "chiffrement applicatif, ou pgcrypto (fourni par defaut)",
    "supabase_vault": "variables d'environnement (clever env import)",
    "pgmq": "add-on Pulsar, ou table de file + tache planifiee",
    "pgjwt": "signature JWT cote application",
    "pg_graphql": "le plus souvent : ne pas porter (verifiez vos appels /graphql/v1)",
    "pg_graphql_public": "idem pg_graphql",
}
INTERNES = {"pg_stat_monitor", "pgjwt", "supautils", "pg_tle"}

exts = {e["nom"]: e.get("version", "?") for e in (releve.get("extensions") or [])}
L = []
p = L.append

p(f"# Votre rapport de migration Supabase → Clever Cloud")
p("")
p(f"*Généré le {datetime.date.today().isoformat()} par `analyser-migration.sh` "
  f"— relevé du {releve.get('horodatage', '?')}. Lecture seule : rien n'a été modifié.*")
p("")
srv = releve.get("serveur") or {}
p(f"**Votre projet** : PostgreSQL {srv.get('version','?')}, {srv.get('taille','?')}, "
  f"{len(exts)} extensions, "
  f"{(releve.get('policies') or {}).get('total','?')} policies RLS.")
p("")

# --- 1. Extensions -----------------------------------------------------------
p("## 1. Vos extensions, une par une")
p("")
ok, tickets, rewrites, inconnues = [], [], [], []
for nom, ver in sorted(exts.items()):
    if nom in REECRIRE:
        rewrites.append((nom, ver, REECRIRE[nom]))
    elif nom in TICKET:
        tickets.append((nom, ver))
    elif nom in DEFAUT:
        ok.append((nom, ver))
    else:
        inconnues.append((nom, ver))

if ok:
    p(f"**Se reprennent telles quelles** ({len(ok)}) — `CREATE EXTENSION` suffit :")
    p("")
    p(", ".join(f"`{n}` {v}" for n, v in ok))
    p("")
if tickets:
    p(f"**À demander au support** ({len(tickets)}) — un ticket, comptez le délai :")
    p("")
    for n, v in tickets:
        p(f"- `{n}` {v}")
    p("")
if rewrites:
    p(f"**Sans équivalent — à remplacer** ({len(rewrites)}) :")
    p("")
    p("| Extension | Remplacement |")
    p("|---|---|")
    for n, v, piste in rewrites:
        p(f"| `{n}` {v} | {piste} |")
    p("")
if inconnues:
    p(f"**À vérifier à la main** ({len(inconnues)}) — hors des listes vérifiées "
      "(certaines sont internes à l'image Supabase et ne se migrent pas) :")
    p("")
    p(", ".join(f"`{n}` {v}" for n, v in inconnues))
    p("")

# --- 2. Points structurants --------------------------------------------------
p("## 2. Les points qui décident de votre architecture")
p("")

tce = releve.get("chiffrement_transparent") or []
if tce:
    p(f"- **Chiffrement transparent pgsodium : {len(tce)} `SECURITY LABEL`.** "
      "Ne se restaure pas par `pg_dump`/`pg_restore`. À remplacer par du "
      "chiffrement applicatif — décision à prendre AVANT la bascule, elle "
      "touche au format des données.")
force = [t["nom"] for t in (releve.get("tables") or []) if t.get("force_rls")]
if force:
    p(f"- **`FORCE ROW LEVEL SECURITY` sur {len(force)} table(s)** "
      f"({', '.join('`'+f+'`' for f in force[:4])}{'…' if len(force) > 4 else ''}). "
      "Vos scripts d'import doivent en tenir compte : ce qui passait avec "
      "`postgres` (BYPASSRLS chez Supabase) peut échouer ailleurs.")
rt = (releve.get("realtime") or {})
if rt.get("tables"):
    p(f"- **Realtime : {len(rt['tables'])} table(s) publiée(s).** Si vous utilisez "
      "*Postgres Changes*, le décodage logique n'est pas ouvert par défaut sur "
      "un add-on managé (demande support, jamais sans accord écrit). "
      "*Broadcast*/*Presence* : un WebSocket applicatif suffit.")
wh = releve.get("webhooks") or {}
if wh.get("triggers"):
    noms = ", ".join("`" + t["nom"] + "`" for t in wh["triggers"][:3])
    p(f"- **{len(wh['triggers'])} Database Webhook(s)** ({noms}) : surcouche "
      "propre à Supabase, à réécrire en appel HTTP applicatif.")
jobs = releve.get("jobs_cron") or []
if jobs:
    p(f"- **{len(jobs)} tâche(s) `pg_cron`** → `clevercloud/cron.json`. "
      "Piège : les crons tournent sur CHAQUE instance — dédupliquez sur "
      "`INSTANCE_NUMBER` (voir `exemple-cible/clevercloud/tache.sh`).")
secrets = releve.get("secrets_vault") or []
if secrets:
    p(f"- **{len(secrets)} secret(s) dans le Vault** → variables "
      "d'environnement (`clever env import`). Gain net : plus de secret "
      "déchiffré au fil des requêtes.")
buckets = releve.get("buckets") or []
if buckets:
    mime = [b for b in buckets if b.get("types_mime")]
    p(f"- **{len(buckets)} bucket(s) Storage** → Cellar (S3). "
      + (f"{len(mime)} imposent des types MIME : cette contrainte est portée "
         "par la base chez Supabase, Cellar ne filtre pas — à réimplémenter "
         "côté application. " if mime else "")
      + "Et une clé Cellar donne accès à tous les buckets de l'add-on.")
p("")

# --- 3. RLS ------------------------------------------------------------------
pol = (releve.get("policies") or {}).get("total") or 0
if pol:
    p("## 3. Vos policies RLS : elles se conservent")
    p("")
    p(f"Vos **{pol} policies** sont du PostgreSQL standard. Ce qui change, ce "
      "sont les rôles (`anon`, `authenticated`) — pas créables par défaut sur "
      "un add-on managé, mais on peut s'en passer entièrement :")
    p("")
    p("```sql")
    p("-- remplacer            auth.uid()")
    p("-- par                  current_setting('app.utilisateur_id', true)::uuid")
    p("-- et poser le contexte par transaction depuis l'application :")
    p("--   select set_config('app.utilisateur_id', $1, true);")
    p("```")
    p("")
    p("Motif complet et sûr sur pool de connexions : `exemple-cible/db.js`.")
    p("")

# --- 4. Checklist support ----------------------------------------------------
p("## 4. Vos demandes au support, prêtes à envoyer")
p("")
demandes = []
if tickets:
    demandes.append("activation des extensions : " + ", ".join(f"`{n}`" for n, _ in tickets))
demandes.append("**nombre maximal de connexions** du plan visé (non publié — "
                "il borne votre autoscaling : pool × instances ≤ ce chiffre)")
demandes.append("chiffrement au repos (plans dédiés uniquement, non actif par défaut)")
demandes.append("**PITR** si votre RPO l'exige — prestation facturée (setup task, "
                "sur devis), à budgéter au provisionnement")
if rt.get("tables"):
    demandes.append("ouverture du décodage logique, si *Postgres Changes* est "
                    "réellement utilisé — réponse écrite avant tout engagement")
for i, d in enumerate(demandes, 1):
    p(f"{i}. {d}")
p("")

# --- 5. Suite ----------------------------------------------------------------
p("## 5. Pour continuer")
p("")
p("- [MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md) — ce qui se passe, mesuré")
p("- [ATTERRIR-SUR-CLEVER-CLOUD.md](ATTERRIR-SUR-CLEVER-CLOUD.md) — le chemin, commande par commande")
p("- [exemple-cible/](exemple-cible/) — le squelette du backend cible")
p("- `scripts/mesures-cout.sh` — chronométrez VOTRE fenêtre de bascule (à vide !)")
p("- `scripts/recette-rls.py` — la matrice qui prouvera que la reprise est fidèle")
p("")
p("*Généré à partir de votre base, en lecture seule. Les correspondances datent "
  "d'août 2026 : revérifiez la documentation avant de vous engager.*")

open(sys.argv[2], "w").write("\n".join(L) + "\n")
print(f"   {sys.argv[2]} : {len(L)} lignes")
PY

echo
echo "Termine. Lisez : $SORTIE_MD"
