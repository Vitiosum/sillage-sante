#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Controle que .env.local est complet, SANS jamais afficher une valeur.
#
#   ./scripts/verifier-env.sh
#
# N'imprime que le nom de la variable et son etat : rempli, vide, ou encore
# sur la valeur d'exemple. A lancer avant deployer.sh et post-deploiement.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FICHIER="$RACINE/.env.local"

if [[ ! -f "$FICHIER" ]]; then
  echo "Absent : .env.local — lancer d'abord : cp .env.example .env.local" >&2
  exit 1
fi

# Le fichier contient la cle service_role : il ne doit etre lisible que par toi.
chmod 600 "$FICHIER"

REQUISES=(
  NEXT_PUBLIC_SUPABASE_URL
  NEXT_PUBLIC_SUPABASE_ANON_KEY
  SUPABASE_SERVICE_ROLE_KEY
  SUPABASE_DB_URL
  DOCUMENTS_ENCRYPTION_KEY
)

# Facultatives : les Edge Functions concernees echouent proprement sans elles.
FACULTATIVES=(BREVO_API_KEY OPENAI_API_KEY ANTIVIRUS_WEBHOOK_TOKEN SUPABASE_JWT_SECRET)

manquantes=0

etat() {
  local nom="$1" obligatoire="$2" valeur
  valeur="$(grep -E "^${nom}=" "$FICHIER" | head -1 | cut -d= -f2- || true)"
  valeur="${valeur%\"}"; valeur="${valeur#\"}"

  if [[ -z "$valeur" ]]; then
    printf '  %-32s VIDE\n' "$nom"
    if [[ "$obligatoire" == oui ]]; then manquantes=$((manquantes + 1)); fi
  elif [[ "$valeur" == *xxxxxxxx* || "$valeur" == *"...."* || "$valeur" == *"super-secret-jwt"* ]]; then
    printf '  %-32s VALEUR D EXEMPLE\n' "$nom"
    if [[ "$obligatoire" == oui ]]; then manquantes=$((manquantes + 1)); fi
  else
    printf '  %-32s rempli (%s caracteres)\n' "$nom" "${#valeur}"
  fi
}

echo "Obligatoires :"
for v in "${REQUISES[@]}"; do etat "$v" oui; done

echo "Facultatives :"
for v in "${FACULTATIVES[@]}"; do etat "$v" non; done

echo
if (( manquantes > 0 )); then
  echo "$manquantes variable(s) obligatoire(s) a renseigner."
  echo "Cles du projet : Dashboard > Project Settings > API"
  exit 1
fi

echo "Complet. Suite : ./scripts/deployer.sh <project-ref>"
