#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() {
  printf '[cobweb][install] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Erro: comando '$1' nao encontrado. Instale-o e tente novamente."
    exit 1
  fi
}

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  require_cmd sudo
  SUDO="sudo"
fi

APT_OPTS=(-y -o Dpkg::Use-Pty=0)
export DEBIAN_FRONTEND=noninteractive

log "Atualizando indices do apt..."
${SUDO} apt-get update

log "Instalando dependencias essenciais..."
${SUDO} apt-get install "${APT_OPTS[@]}" nginx

if ${SUDO} dpkg -l | awk '{print $2}' | grep -q "^certbot$"; then
  log "Removendo pacote certbot do apt para evitar conflito..."
  ${SUDO} apt-get remove "${APT_OPTS[@]}" certbot
  ${SUDO} apt-get autoremove "${APT_OPTS[@]}" || true
fi

if ! command -v snap >/dev/null 2>&1; then
  log "Instalando snapd (necessario para o certbot moderno)..."
  ${SUDO} apt-get install "${APT_OPTS[@]}" snapd
  ${SUDO} systemctl enable --now snapd.socket >/dev/null
fi

log "Instalando/atualizando certbot via snap (suporte TLS-ALPN)..."
${SUDO} snap install core >/dev/null
${SUDO} snap refresh core >/dev/null
if ! ${SUDO} snap list | awk '{print $1}' | grep -q "^certbot$"; then
  ${SUDO} snap install --classic certbot >/dev/null
else
  ${SUDO} snap refresh certbot >/dev/null
fi

if [[ ! -L /usr/bin/certbot || "$(readlink -f /usr/bin/certbot)" != "/snap/bin/certbot" ]]; then
  log "Criando link simbolico para usar o certbot do snap..."
  ${SUDO} ln -sf /snap/bin/certbot /usr/bin/certbot
fi

log "Garantindo estrutura de diretorios do projeto..."
mkdir -p "${PROJECT_ROOT}/config"
mkdir -p "${PROJECT_ROOT}/templates"

NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
DEFAULT_SITE="${NGINX_ENABLED_DIR}/default"
if [[ -L "${DEFAULT_SITE}" || -f "${DEFAULT_SITE}" ]]; then
  log "Removendo site padrao do Nginx (${DEFAULT_SITE})..."
  ${SUDO} rm -f "${DEFAULT_SITE}"
fi

log "Habilitando servico do Nginx para iniciar com o sistema..."
${SUDO} systemctl enable nginx >/dev/null

log "Garantindo que o Nginx esteja parado (a configuracao sera aplicada futuramente)..."
${SUDO} systemctl stop nginx >/dev/null 2>&1 || true

log "Dependencias instaladas com sucesso."
