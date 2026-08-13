#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploiement de Sillage Sante sur un projet Supabase Cloud.
#
#   ./scripts/deployer.sh <project-ref>
#
# Prerequis :
#   - Supabase CLI                : brew install supabase/tap/supabase
#                                   (l'install npm globale n'est plus supportee)
#   - Session ouverte             : supabase login
#   - .env.local renseigne        : cp .env.example .env.local
#
# Optionnel mais recommande :
#   - scripts/prerequis.sql passe dans le SQL Editor. Les migrations savent
#     s'en passer (elles activent les extensions dans des blocs tolerants),
#     mais pg_cron active depuis une migration laisse des GRANTs incomplets.
#
# Verifie contre la CLI 2.114.0 en aout 2026.
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
# --include-all : les migrations sont horodatees en janvier, un projet cree
# plus tard les considererait sinon comme anterieures a son point de depart.
supabase db push --include-all

echo "==> 3/5  Envoi des secrets des Edge Functions"
# Les valeurs viennent de .env.local, jamais du depot.
# Les variables prefixees SUPABASE_ ne sont pas acceptees comme secrets de
# fonction : elles sont deja injectees dans le runtime. Les envoyer produit
# un rejet silencieux, on les filtre donc explicitement.
# Les variables vides sont ecartees aussi : les pousser n'apporte rien et
# masque ce qui est reellement configure.
umask 077
grep -vE '^\s*(#|$)|^SUPABASE_|^NEXT_PUBLIC_|^[A-Za-z_][A-Za-z0-9_]*=\s*$' \
  .env.local > .env.secrets.tmp
echo "Variables poussees :"
cut -d= -f1 .env.secrets.tmp
supabase secrets set --env-file .env.secrets.tmp
rm -f .env.secrets.tmp

echo "==> 4/5  Deploiement des Edge Functions"
# Pas de --no-verify-jwt : en CLI 2.x c'est supabase/config.toml qui fait foi
# (verifie apres deploiement via `supabase functions list`).
supabase functions deploy

echo "==> 5/5  Etat du projet"
supabase functions list
supabase migration list

cat <<'FIN'

Reste a faire a la main (aucune de ces trois etapes n'est scriptable) :
  1. SQL Editor : scripts/post-deploiement.sql, en remplacant
     <PROJECT_REF> et <SERVICE_ROLE_KEY>.
  2. Authentication > Hooks : activer "Custom Access Token" et pointer
     vers auth_hooks.custom_access_token. Sans ca, la moitie des policies
     RLS renvoie zero ligne et on croit a un bug.
  3. Creer deux comptes de test (voir DEPLOIEMENT.md, etape 7).

FIN
