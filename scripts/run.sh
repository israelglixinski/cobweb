#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[cobweb][run] %s\n' "$*"
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

if ${SUDO} systemctl is-active --quiet nginx; then
  log "Nginx em execucao - aplicando reload."
  ${SUDO} systemctl reload nginx
else
  log "Iniciando servico do Nginx."
  ${SUDO} systemctl start nginx
fi

log "Status do Nginx:"
${SUDO} systemctl status nginx --no-pager --lines=3 || true
