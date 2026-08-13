#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Prepare scripts/post-deploiement.sql pour execution, SANS jamais ecrire la
# cle service_role dans un fichier suivi par git.
#
#   ./scripts/post-deploiement.sh <project-ref>
#
# Lit SUPABASE_SERVICE_ROLE_KEY dans .env.local, produit
# scripts/post-deploiement.local.sql (ignore par git), et s'arrete la.
# A toi de coller ce fichier dans le SQL Editor du dashboard.
#
# Pourquoi ce detour : le depot est public et la procedure documente
# `git add .`. Substituer <SERVICE_ROLE_KEY> directement dans le .sql suivi
# publie la cle au commit suivant.
# ---------------------------------------------------------------------------
set -euo pipefail

REF="${1:-}"
if [[ -z "$REF" ]]; then
  echo "Usage : $0 <project-ref>" >&2
  exit 1
fi

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RACINE="$(dirname "$ICI")"
SOURCE="$ICI/post-deploiement.sql"
CIBLE="$ICI/post-deploiement.local.sql"

if [[ ! -f "$RACINE/.env.local" ]]; then
  echo "Erreur : $RACINE/.env.local introuvable. Faire d'abord : cp .env.example .env.local" >&2
  exit 1
fi

# shellcheck disable=SC1091
CLE="$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' "$RACINE/.env.local" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"

if [[ -z "$CLE" ]]; then
  echo "Erreur : SUPABASE_SERVICE_ROLE_KEY vide dans .env.local." >&2
  echo "         Dashboard > Project Settings > API > service_role" >&2
  exit 1
fi

# Le fichier genere est en 600 : il contient une cle qui contourne toutes les RLS.
umask 077
sed -e "s|<PROJECT_REF>|$REF|g" -e "s|<SERVICE_ROLE_KEY>|$CLE|g" "$SOURCE" > "$CIBLE"

cat <<FIN

Genere : $CIBLE  (ignore par git, permissions 600)

Etape suivante, a la main :
  1. Ouvrir https://supabase.com/dashboard/project/$REF/sql/new
  2. Coller le contenu de post-deploiement.local.sql
  3. Run

Puis supprimer le fichier :
  rm $CIBLE

FIN
