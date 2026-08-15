#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tâche planifiée — remplace un job pg_cron qui appelait pg_net.
#
# Référencé depuis clevercloud/cron.json. Rendre exécutable AVANT le commit :
#     git update-index --chmod=+x clevercloud/tache.sh
#
# LE PIÈGE QU'IL RÉSOUT
# ---------------------
# Les crons Clever Cloud s'exécutent sur CHAQUE instance. Avec trois instances,
# la tâche part trois fois. Le clustering n'est pas supporté : la déduplication
# est à la charge de l'application.
#
# En base, pg_cron tournait une fois — il n'y a qu'une base. Ici, autant de fois
# qu'il y a d'instances. C'est la régression la plus courante de cette
# migration, et la plus discrète : un rappel envoyé en triple se remarque, une
# purge lancée en triple beaucoup moins.
#
# Deux autres différences avec pg_cron : `@reboot` n'existe pas (la crontab est
# posée après le démarrage), et les chemins doivent être absolus — d'où $ROOT.
# ---------------------------------------------------------------------------
set -euo pipefail

# Une seule instance exécute les tâches planifiées.
if [[ "${INSTANCE_NUMBER:-0}" != "0" ]]; then
  echo "instance ${INSTANCE_NUMBER} : tâche ignorée (déduplication)"
  exit 0
fi

TACHE="${1:-}"
[[ -n "$TACHE" ]] || { echo "usage : $0 <nom-de-tache>" >&2; exit 1; }

# La tâche appelle sa propre application. Ce qui était une logique invisible
# dans un trigger devient une route testable hors production.
BASE="http://localhost:${PORT:-8080}"
JETON="${API_SERVICE_TOKEN:?API_SERVICE_TOKEN non défini}"

echo "$(date -u +%FT%TZ) démarrage $TACHE"

CODE=$(curl -sS -o /tmp/"$TACHE".out -w '%{http_code}' \
  -X POST "$BASE/taches/$TACHE" \
  -H "Authorization: Bearer $JETON" \
  -H 'Content-Type: application/json' \
  --max-time 300 -d '{}')

echo "$(date -u +%FT%TZ) $TACHE -> HTTP $CODE"
head -c 500 /tmp/"$TACHE".out; echo

# Sortir en erreur si l'appel a échoué : la sortie du cron atterrit dans les
# logs de l'application, c'est le seul endroit où l'on verra qu'une tâche est
# morte.
[[ "$CODE" =~ ^2 ]] || exit 1
