#!/usr/bin/env bash
# LowziCRM — ponto de entrada portátil (Linux e macOS).
set -euo pipefail

REPO_URL="${LOWZICRM_REPO_URL:-https://github.com/WeslleyMouraDev/LowziCRM.git}"
INSTALL_DIR="${LOWZICRM_HOME:-$HOME/lowzicrm}"
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [ -x "$HERE/scripts/deploy.sh" ]; then
  exec "$HERE/scripts/deploy.sh" install "$@"
fi

command -v git >/dev/null 2>&1 || {
  printf 'Git não está instalado. Instale o Git e execute novamente.\n' >&2
  exit 1
}

if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

exec "$INSTALL_DIR/scripts/deploy.sh" install "$@"
