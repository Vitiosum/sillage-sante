#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploiement de Sillage Sante sur un projet Supabase Cloud.
#
#   ./scripts/deployer.sh <project-ref>
#
# Prerequis :
#   - Supabase CLI installee      : npm i -g supabase
#   - Session ouverte             : supabase login
#   - scripts/prerequis.sql deja passe dans le SQL Editor
#   - .env.local renseigne
# ---------------------------------------------------------------------------
set -euo pipefail

REF="${1:-}"
if [[ -z "$REF" ]]; then
  echo "Usage : $0 <project-ref>   (visible dans l'URL du dashboard)" >&2
  exit 1
fi

echo "==> 1/5  Liaison au projet $REF"
supabase link --project-ref "$REF"

echo "==> 2/5  Application des migrations"
supabase db push

echo "==> 3/5  Envoi des secrets des Edge Functions"
# Les valeurs viennent de .env.local, jamais du depot.
supabase secrets set --env-file .env.local

echo "==> 4/5  Deploiement des Edge Functions"
supabase functions deploy rappel-rdv          --no-verify-jwt
supabase functions deploy document-scan       --no-verify-jwt
supabase functions deploy ordonnance-pdf
supabase functions deploy recherche-semantique
supabase functions deploy traiter-files      --no-verify-jwt

echo "==> 5/5  Etat du projet"
supabase functions list
supabase migration list

cat <<'FIN'

Reste a faire a la main :
  1. SQL Editor : scripts/post-deploiement.sql, en remplacant
     <PROJECT_REF> et <SERVICE_ROLE_KEY>.
  2. Authentication > Hooks : activer "Custom Access Token" et pointer
     vers auth_hooks.custom_access_token.
  3. Creer deux comptes de test (voir DEPLOIEMENT.md, etape 7).

FIN
