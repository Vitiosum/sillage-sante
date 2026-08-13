#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cree les trois comptes de demonstration via l'API Admin de GoTrue.
#
#   ./scripts/comptes-demo.sh
#
# Lit SUPABASE_SERVICE_ROLE_KEY et NEXT_PUBLIC_SUPABASE_URL dans .env.local.
#
# Les comptes ne sont PAS crees en SQL : le trigger medical.gerer_nouvel_
# utilisateur() se declenche sur insert dans auth.users et lit
# raw_app_meta_data ->> 'role_metier'. C'est donc app_metadata au moment de la
# creation qui determine le role metier — le modifier ensuite ne rejoue pas le
# trigger et ne cree pas la fiche correspondante.
#
# Aucun mot de passe : les comptes sont en email_confirm, connexion par
# magic link. Rien a stocker, rien a faire tourner.
#
# Enchainer ensuite :
#   psql "$SUPABASE_DB_URL" -f scripts/donnees-demo.sql
# ---------------------------------------------------------------------------
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVF="$RACINE/.env.local"

[[ -f "$ENVF" ]] || { echo "Absent : .env.local" >&2; exit 1; }

CLE="$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' "$ENVF" | head -1 | cut -d= -f2-)"
URL="$(grep -E '^NEXT_PUBLIC_SUPABASE_URL=' "$ENVF" | head -1 | cut -d= -f2-)"

[[ -n "$CLE" && -n "$URL" ]] || { echo "SUPABASE_SERVICE_ROLE_KEY ou NEXT_PUBLIC_SUPABASE_URL vide" >&2; exit 1; }

creer() {
  curl -s -X POST "$URL/auth/v1/admin/users" \
    -H "apikey: $CLE" -H "Authorization: Bearer $CLE" \
    -H "Content-Type: application/json" -d "$1" |
  python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'id' in d:
    role = (d.get('app_metadata') or {}).get('role_metier', 'patient (defaut)')
    print('OK   %-28s %s  role=%s' % (d['email'], d['id'], role))
else:
    print('ERR  ' + json.dumps(d)[:200])
"
}

creer '{"email":"praticien@example.test","email_confirm":true,"app_metadata":{"role_metier":"praticien"},"user_metadata":{"nom":"Kerguelen","prenom":"Anne"}}'
creer '{"email":"patient@example.test","email_confirm":true,"user_metadata":{"nom":"Le Goff","prenom":"Yann","date_naissance":"1984-03-12"}}'
creer '{"email":"secretariat@example.test","email_confirm":true,"app_metadata":{"role_metier":"secretariat"},"user_metadata":{"nom":"Morvan","prenom":"Claire"}}'

cat <<'FIN'

Le compte secretariat est cree volontairement : il sert a montrer que le
troisieme role metier annonce par le README n'a aucun acces reel (le modele
n'a pas de lien secretaire-cabinet). Voir CONSTATS-DEPLOIEMENT.md.

Suite :
  psql "$SUPABASE_DB_URL" -f scripts/donnees-demo.sql
FIN
