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
${SUDO} apt-get install "${APT_OPTS[@]}" nginx curl socat cron

log "Garantindo que o cron esteja habilitado para execucao das renovações..."
${SUDO} systemctl enable --now cron >/dev/null 2>&1 || true

# Remover installacoes anteriores de certbot para evitar conflitos conceituais
if ${SUDO} dpkg -l | awk '{print $2}' | grep -q "^certbot$"; then
  log "Removendo pacote certbot do apt (usaremos acme.sh)..."
  ${SUDO} apt-get remove "${APT_OPTS[@]}" certbot
  ${SUDO} apt-get autoremove "${APT_OPTS[@]}" || true
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

ACME_HOME="/opt/acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
ACME_CERT_HOME="${ACME_HOME}/certs"
ACME_DEFAULT_EMAIL="${ACME_DEFAULT_EMAIL:-}"

if [[ ! -f "${ACME_BIN}" ]]; then
  log "Instalando acme.sh (cliente ACME com suporte a TLS-ALPN)..."
  require_cmd curl
  TMP_INSTALL_SCRIPT="$(mktemp)"
  curl -fsSL https://get.acme.sh -o "${TMP_INSTALL_SCRIPT}"
  ACME_INSTALL_ARGS=(
    "--home" "${ACME_HOME}"
    "--config-home" "${ACME_HOME}"
    "--cert-home" "${ACME_CERT_HOME}"
  )
  if [[ -n "${ACME_DEFAULT_EMAIL}" ]]; then
    ACME_INSTALL_ARGS=("email=${ACME_DEFAULT_EMAIL}" "${ACME_INSTALL_ARGS[@]}")
  fi
  if ! ${SUDO} sh "${TMP_INSTALL_SCRIPT}" "${ACME_INSTALL_ARGS[@]}" >/dev/null; then
    rm -f "${TMP_INSTALL_SCRIPT}"
    log "Falha ao instalar acme.sh. Verifique se o pacote 'cron' esta presente ou use ACME_DEFAULT_EMAIL."
    exit 1
  fi
  rm -f "${TMP_INSTALL_SCRIPT}"
else
  log "Atualizando acme.sh..."
  ${SUDO} "${ACME_BIN}" --home "${ACME_HOME}" --upgrade >/dev/null
fi

${SUDO} mkdir -p "${ACME_HOME}" "${ACME_CERT_HOME}"

if [[ ! -f "${ACME_BIN}" ]]; then
  log "Erro: instalacao do acme.sh nao produziu ${ACME_BIN}."
  exit 1
fi

${SUDO} chmod +x "${ACME_BIN}"

if [[ ! -L /usr/local/bin/acme.sh || "$(readlink -f /usr/local/bin/acme.sh 2>/dev/null)" != "${ACME_BIN}" ]]; then
  log "Criando link simbolico /usr/local/bin/acme.sh..."
  ${SUDO} ln -sf "${ACME_BIN}" /usr/local/bin/acme.sh
fi

log "Configurando acme.sh para usar Let's Encrypt como autoridade padrao..."
${SUDO} "${ACME_BIN}" --home "${ACME_HOME}" --set-default-ca --server letsencrypt >/dev/null

log "Dependencias instaladas com sucesso."
