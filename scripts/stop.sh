#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[cobweb][stop] %s\n' "$*"
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

require_cmd systemctl

if ${SUDO} systemctl is-active --quiet nginx; then
  log "Parando Nginx..."
  ${SUDO} systemctl stop nginx
else
  log "Nginx ja estava parado."
fi

log "Nginx interrompido."
