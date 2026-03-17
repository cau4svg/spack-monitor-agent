#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/spack-monitor"
SERVICE_NAME="spack-monitor.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERRO: $*"
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Execute como root. Exemplo: sudo bash uninstall.sh"
  fi
}

remove_service() {
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    log "Parando servico ${SERVICE_NAME}..."
    systemctl stop "$SERVICE_NAME" || true
    systemctl disable "$SERVICE_NAME" || true
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    log "Removendo ${SERVICE_FILE}..."
    rm -f "$SERVICE_FILE"
  fi

  systemctl daemon-reload
  systemctl reset-failed || true
}

remove_files() {
  if [[ -d "$INSTALL_DIR" ]]; then
    log "Removendo ${INSTALL_DIR}..."
    rm -rf "$INSTALL_DIR"
  fi
}

main() {
  require_root
  remove_service
  remove_files
  log "Desinstalacao concluida."
}

main "$@"
