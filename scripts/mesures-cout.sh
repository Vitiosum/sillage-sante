#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Chronometre ce qui coute pendant une bascule. Sortie JSON.
#
#   SUPABASE_DB_URL='postgresql://...' ./mesures-cout.sh [dossier_sortie]
#
# Mesure, dans l'ordre :
#   1. pg_dump du schema, des donnees, de auth+storage : duree et taille
#   2. le rapport taille du dump / taille de la table, qui n'est PAS 1
#   3. la faisabilite et la duree de reconstruction de chaque index vectoriel
#
# Ces trois chiffres suffisent a annoncer une fenetre de bascule defendable.
# Sans eux, toute duree annoncee est une invention.
#
# Prerequis : pg_dump et psql natifs. `supabase db dump` exige Docker meme
# contre une base distante : on ne l'utilise pas.
#
# LANCER A VIDE. Le script reconstruit reellement les index vectoriels : il
# les SUPPRIME puis les recree. Pendant ce temps les recherches vectorielles
# tombent en scan sequentiel. Ne pas jouer en production aux heures ouvrees.
# Et sur un petit gabarit, toute charge concurrente fausse les durees d'un
# facteur 5 : mesurer sur une base au repos, sinon la fourchette annoncee au
# client ne vaut rien.
# ---------------------------------------------------------------------------
set -euo pipefail

U="${SUPABASE_DB_URL:-}"
[[ -n "$U" ]] || { echo "SUPABASE_DB_URL non definie" >&2; exit 1; }

SORTIE="${1:-.}"
mkdir -p "$SORTIE"

# chrono <fichier_erreurs> <commande...>  ->  "<duree>;<code retour>"
# Conserver stderr et le code : un pg_dump qui echoue (version pg_dump trop
# ancienne, disque plein, coupure) produisait sinon un chiffre credible et
# faux — le pire des resultats pour dimensionner une bascule.
chrono() {
  local debut fin code
  debut=$(date +%s)
  "${@:2}" 2>"$1"; code=$?
  fin=$(date +%s)
  echo "$((fin - debut));$code"
}
duree()  { echo "${1%%;*}"; }
code()   { echo "${1##*;}"; }
alerte() {                       # alerte <nom> <resultat> <fichier_erreurs>
  if [[ "$(code "$2")" != "0" ]]; then
    echo "ECHEC $1 (code $(code "$2")) :" >&2
    tail -3 "$3" >&2
  fi
}

taille() { [[ -f "$1" ]] && wc -c < "$1" | tr -d ' ' || echo 0; }

# Les schemas metier : tout sauf ceux de la plateforme.
SCHEMAS=$(psql "$U" -tAX -c "
  select string_agg('--schema=' || nspname, ' ')
    from pg_namespace
   where nspname not like 'pg\\_%'
     and nspname not in ('information_schema','auth','storage','realtime','vault',
                         'extensions','graphql','graphql_public','net','cron',
                         'pgsodium','pgsodium_masks','supabase_migrations',
                         'supabase_functions','pgmq','pgmq_public')" 2>/dev/null)

echo "-- dump du schema" >&2
R_SCHEMA=$(chrono "$SORTIE/schema.err" pg_dump "$U" --schema-only $SCHEMAS -f "$SORTIE/dump_schema.sql")
alerte "dump schema" "$R_SCHEMA" "$SORTIE/schema.err"
echo "-- dump des donnees (le plus long)" >&2
R_DATA=$(chrono "$SORTIE/data.err" pg_dump "$U" --data-only $SCHEMAS -f "$SORTIE/dump_data.sql")
alerte "dump donnees" "$R_DATA" "$SORTIE/data.err"
echo "-- dump auth et storage" >&2
R_AUTH=$(chrono "$SORTIE/auth.err" pg_dump "$U" --schema=auth --schema=storage -f "$SORTIE/dump_auth.sql")
alerte "dump auth" "$R_AUTH" "$SORTIE/auth.err"

OCTETS_BASE=$(psql "$U" -tAX -c "select pg_database_size(current_database())")

# Reconstruction des index vectoriels : le cout cache d'une migration pgvector.
# On mesure d'abord avec le maintenance_work_mem par defaut, ce qui echoue
# souvent sur un petit gabarit, puis avec une valeur relevee.
INDEX_JSON=$(psql "$U" -tAX -c "
  select coalesce(jsonb_agg(jsonb_build_object(
    'nom', indexname, 'schema', schemaname, 'definition', indexdef,
    'taille_octets', pg_relation_size((quote_ident(schemaname)||'.'||quote_ident(indexname))::regclass))), '[]'::jsonb)::text
    from pg_indexes where indexdef ~* 'ivfflat|hnsw'" 2>/dev/null || echo '[]')

MESURES_INDEX="[]"
if [[ "$INDEX_JSON" != "[]" ]]; then
  MESURES_INDEX=$(python3 - "$U" "$INDEX_JSON" <<'PY'
import json, subprocess, sys, time

url, brut = sys.argv[1], sys.argv[2]
sortie = []

for idx in json.loads(brut):
    nom, schema, ddl = idx["nom"], idx["schema"], idx["definition"]
    entree = {"index": f"{schema}.{nom}", "taille_octets": idx["taille_octets"]}

    def sql(req, mwm=None):
        prefixe = f"set statement_timeout='30min'; "
        if mwm:
            prefixe += f"set maintenance_work_mem='{mwm}'; "
        t = time.time()
        p = subprocess.run(["psql", url, "-qX", "-v", "ON_ERROR_STOP=1", "-c", prefixe + req],
                           capture_output=True, text=True, timeout=2000)
        return p.returncode, (p.stderr or "").strip(), round(time.time() - t, 1)

    rc, err, _ = sql(f'drop index {schema}.{nom}')
    if rc != 0:
        entree["erreur"] = f"suppression impossible : {err[:160]}"
        sortie.append(entree); continue

    # Tentative au parametrage par defaut du gabarit.
    rc, err, d = sql(ddl)
    if rc == 0:
        entree.update(defaut_suffisant=True, duree_s=d)
    else:
        entree.update(defaut_suffisant=False, erreur_defaut=err.splitlines()[0][:160] if err else "")
        rc, err, d = sql(ddl, "256MB")
        if rc == 0:
            entree.update(duree_s=d, maintenance_work_mem_requis="256MB")
        else:
            # Ultime filet : ne JAMAIS laisser la base source sans son index.
            rc2, err2, _ = sql(ddl, "1GB")
            if rc2 == 0:
                entree.update(maintenance_work_mem_requis="1GB",
                              note="reconstruit au filet 1GB, mesure non representative")
            else:
                entree.update(erreur=err.splitlines()[0][:160] if err else "echec",
                              INDEX_ABSENT=True, restauration_manuelle=ddl)
                print(f"ATTENTION : index {schema}.{nom} ABSENT de la base — "
                      f"rejouer le DDL fourni dans restauration_manuelle", file=sys.stderr)
    entree.setdefault("definition", ddl)
    sortie.append(entree)

print(json.dumps(sortie))
PY
)
fi

cat <<JSON
{
  "horodatage": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "base_octets": $OCTETS_BASE,
  "dumps": {
    "schema":  { "duree_s": $(duree "$R_SCHEMA"), "code": $(code "$R_SCHEMA"), "octets": $(taille "$SORTIE/dump_schema.sql") },
    "donnees": { "duree_s": $(duree "$R_DATA"),   "code": $(code "$R_DATA"),   "octets": $(taille "$SORTIE/dump_data.sql") },
    "auth":    { "duree_s": $(duree "$R_AUTH"),   "code": $(code "$R_AUTH"),   "octets": $(taille "$SORTIE/dump_auth.sql") }
  },
  "index_vectoriels": $MESURES_INDEX,
  "lecture": [
    "MESURER A VIDE. Sur un petit gabarit, la contention fausse tout : le meme dump a pris 102 s puis 495 s selon qu'une autre charge tournait ou non. Facteur 5. Ne rien annoncer sur une mesure unique prise pendant qu'autre chose interroge la base.",
    "Le dump texte gonfle les vecteurs : pg_dump ecrit [0.123,...] la ou la table stocke du float4 binaire. Extrapoler sur l octet de dump, jamais sur la taille de table.",
    "defaut_suffisant=false signifie que l index est IRRECONSTRUCTIBLE sur ce gabarit, donc VACUUM FULL l est aussi. C est un critere de dimensionnement de la cible, pas un detail.",
    "Ajouter le temps de transfert et de restauration : ces mesures ne couvrent que l extraction.",
    "Annoncer une fourchette, pas un chiffre : borne basse a vide, borne haute sous charge."
  ]
}
JSON
