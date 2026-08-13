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

# Directement dans le presse-papier : le SQL Editor empile le contenu des
# onglets, un copier-coller manuel finit par executer trois scripts a la file.
if command -v pbcopy >/dev/null 2>&1; then
  pbcopy < "$CIBLE"
  COPIE="  (deja dans le presse-papier)"
else
  COPIE=""
fi

cat <<FIN

Genere : $CIBLE  (ignore par git, permissions 600)$COPIE

Etape suivante, a la main :
  1. https://supabase.com/dashboard/project/$REF/sql/new
     Ouvrir un onglet VIDE : le SQL Editor conserve le contenu precedent.
  2. Coller, puis Run.
  3. Le second select doit rendre une longueur egale a celle de la cle du
     dashboard. 26 caracteres = la valeur par defaut, le secret n'a pas pris.

Puis supprimer le fichier, il contient la cle en clair :
  rm $CIBLE

FIN
