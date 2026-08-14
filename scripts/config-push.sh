#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pousse supabase/config.toml vers le projet distant, SANS alterer le fichier.
#
#   ./scripts/config-push.sh
#
# POURQUOI CE DETOUR
# ------------------
# config.toml est le CORPUS DE TEST : il declare la surface Supabase que le
# plan de migration doit trouver — SMTP Brevo, gabarits d'e-mail surcharges,
# OIDC Pro Sante Connect, OAuth Google. Le neutraliser pour faire passer un
# push reviendrait a desamorcer l'exercice : une analyse lirait
# « enabled = false, donc a ne pas porter ».
#
# Or trois sections empechent `supabase config push` d'aboutir sur ce
# deploiement :
#
#   1. [auth.email.template.*] — le plan gratuit refuse toute modification de
#      gabarit tant qu'aucun SMTP custom n'est configure :
#      400 "Email template modification is not available for free tier
#           projects using the default email provider."
#   2. [auth.email.smtp] et les providers OIDC — la CLI NE RESOUT PAS les
#      env() absents : elle pousse la chaine "env(SMTP_USER)" telle quelle.
#
# Et le bloc [auth] part en UN SEUL appel API : une seule sous-section
# invalide fait echouer tout le reste, hook custom_access_token compris.
#
# Ce script neutralise donc ces sections dans une COPIE TEMPORAIRE, pousse,
# puis restaure. Le fichier suivi par git n'est jamais modifie.
# ---------------------------------------------------------------------------
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$RACINE/supabase/config.toml"
SAUVE="$(mktemp)"

# Restauration systematique, y compris en cas d'erreur ou d'interruption.
restaurer() {
  if [[ -s "$SAUVE" ]]; then
    cp "$SAUVE" "$CONF"
    rm -f "$SAUVE"
    echo "config.toml restaure dans son etat d'origine"
  fi
}
trap restaurer EXIT INT TERM

cp "$CONF" "$SAUVE"

python3 - "$CONF" <<'PY'
import re, sys, pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text()

# Commente les sections que le plan gratuit ou l'absence d'env() font echouer.
for section in ("auth.email.smtp",
                "auth.email.template.magic_link",
                "auth.email.template.invite"):
    motif = re.compile(rf"^\[{re.escape(section)}\]\n(?:(?!\[).*\n)*", re.M)
    t = motif.sub(lambda m: "".join("# " + l + "\n" for l in m.group(0).rstrip("\n").splitlines()) + "\n", t)

# Desactive les providers dont les credentials ne sont pas fournis.
for section in ("auth.external.keycloak", "auth.external.google"):
    bloc = re.compile(rf"(^\[{re.escape(section)}\]\n(?:(?!\[).*\n)*)", re.M)
    def off(m):
        return re.sub(r"^enabled = true$", "enabled = false", m.group(1), flags=re.M)
    t = bloc.sub(off, t)

p.write_text(t)
print("sections neutralisees dans la copie de travail")
PY

echo "==> supabase config push"
NEXT_PUBLIC_SITE_URL="${NEXT_PUBLIC_SITE_URL:-http://localhost:3000}" \
  supabase config push

echo
echo "Pousse. Rappel : sur le projet distant, SMTP, gabarits d'e-mail et OIDC"
echo "restent inactifs — c'est une limite du deploiement, pas du corpus."
