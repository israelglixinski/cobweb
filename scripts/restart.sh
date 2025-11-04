#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[cobweb][restart] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Erro: comando '$1' nao encontrado."
    exit 1
  fi
}

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  require_cmd sudo
  SUDO="sudo"
fi

require_cmd nginx
require_cmd systemctl

${SUDO} nginx -t
log "Reiniciando Nginx..."
${SUDO} systemctl restart nginx
log "Reinicio concluido."
