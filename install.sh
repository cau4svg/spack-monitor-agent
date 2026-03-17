#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/spack-monitor"
ENV_FILE="${INSTALL_DIR}/.env.monitor"
SERVICE_NAME="spack-monitor.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
MONITOR_SOURCE="${REPO_ROOT}/src/monitor.sh"
SYSTEMD_SOURCE="${REPO_ROOT}/systemd/spack-monitor.service"
ENV_EXAMPLE_SOURCE="${REPO_ROOT}/.env.monitor.example"

DETECTED_PM2_BIN=""
DETECTED_PM2_HOME=""
DETECTED_PM2_NAME=""
DETECTED_SERVER_NAME=""
DETECTED_HEALTH_URL=""
DETECTED_HOST_LABEL=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERRO: $*"
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Execute como root. Exemplo: sudo bash install.sh"
  fi
}

ensure_source_files() {
  [[ -f "$MONITOR_SOURCE" ]] || fail "Arquivo ausente: $MONITOR_SOURCE"
  [[ -f "$SYSTEMD_SOURCE" ]] || fail "Arquivo ausente: $SYSTEMD_SOURCE"
  [[ -f "$ENV_EXAMPLE_SOURCE" ]] || fail "Arquivo ausente: $ENV_EXAMPLE_SOURCE"
}

install_dependencies() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log "apt-get nao encontrado; pulando instalacao automatica de dependencias."
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  log "Instalando dependencias base..."
  apt-get update
  apt-get install -y curl ca-certificates procps
}

read_existing_value() {
  local key="$1"
  local line=""

  if [[ -f "$ENV_FILE" ]]; then
    line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
  fi

  printf '%s' "${line#*=}" | tr -d '\r'
}

choose_value() {
  local current="$1"
  local fallback="$2"

  if [[ -n "$current" ]]; then
    printf '%s' "$current"
  else
    printf '%s' "$fallback"
  fi
}

prepend_path() {
  local candidate="$1"

  [[ -d "$candidate" ]] || return 0

  case ":${PATH}:" in
    *":${candidate}:"*) ;;
    *) PATH="${candidate}:${PATH}" ;;
  esac
}

extend_pm2_path() {
  local candidate=""

  prepend_path "/usr/local/sbin"
  prepend_path "/usr/local/bin"
  prepend_path "/usr/sbin"
  prepend_path "/usr/bin"
  prepend_path "/sbin"
  prepend_path "/bin"

  shopt -s nullglob
  for candidate in /root/.nvm/versions/node/*/bin /home/*/.nvm/versions/node/*/bin; do
    prepend_path "$candidate"
  done
  shopt -u nullglob
}

discover_pm2_bin() {
  local existing_pm2_bin=""
  local candidate=""

  existing_pm2_bin="$(read_existing_value PM2_BIN)"
  if [[ -n "$existing_pm2_bin" && -x "$existing_pm2_bin" ]]; then
    DETECTED_PM2_BIN="$existing_pm2_bin"
    return 0
  fi

  if command -v pm2 >/dev/null 2>&1; then
    DETECTED_PM2_BIN="$(command -v pm2)"
    return 0
  fi

  shopt -s nullglob
  for candidate in \
    /root/.nvm/versions/node/*/bin/pm2 \
    /home/*/.nvm/versions/node/*/bin/pm2 \
    /usr/local/bin/pm2 \
    /usr/bin/pm2
  do
    if [[ -x "$candidate" ]]; then
      DETECTED_PM2_BIN="$candidate"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  fail "Nao foi possivel localizar o binario do PM2."
}

guess_pm2_home() {
  local existing_pm2_home=""

  existing_pm2_home="$(read_existing_value PM2_HOME)"
  if [[ -n "$existing_pm2_home" ]]; then
    DETECTED_PM2_HOME="$existing_pm2_home"
    return 0
  fi

  if [[ -n "${PM2_HOME:-}" ]]; then
    DETECTED_PM2_HOME="$PM2_HOME"
    return 0
  fi

  case "$DETECTED_PM2_BIN" in
    /home/*)
      DETECTED_PM2_HOME="$(printf '%s' "$DETECTED_PM2_BIN" | awk -F/ '{print "/" $2 "/" $3 "/.pm2"}')"
      ;;
    /root/*)
      DETECTED_PM2_HOME="/root/.pm2"
      ;;
    *)
      DETECTED_PM2_HOME="/root/.pm2"
      ;;
  esac
}

discover_pm2_process() {
  local list_output=""
  local matches=""
  local match_count=""

  export PM2_HOME="$DETECTED_PM2_HOME"
  list_output="$("$DETECTED_PM2_BIN" list --no-color 2>/dev/null || true)"
  matches="$(printf '%s\n' "$list_output" | grep -oE 'apiwhatsapp-[A-Za-z0-9_-]+' | awk '!seen[$0]++')"
  match_count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$match_count" -lt 1 ]]; then
    fail "Nenhum processo PM2 no padrao apiwhatsapp-XXXX foi encontrado."
  fi

  DETECTED_PM2_NAME="$(printf '%s\n' "$matches" | sed -n '1p')"

  if [[ "$match_count" -gt 1 ]]; then
    log "Mais de um processo detectado. Usando o primeiro: ${DETECTED_PM2_NAME}"
  fi
}

derive_runtime_values() {
  local suffix=""

  suffix="${DETECTED_PM2_NAME#apiwhatsapp-}"
  DETECTED_SERVER_NAME="WHATSAPP-${suffix^^}"
  DETECTED_HEALTH_URL="https://${DETECTED_PM2_NAME}.apibrasil.com.br"
  DETECTED_HOST_LABEL="$(hostname -s 2>/dev/null || hostname)"
}

install_project_files() {
  log "Copiando arquivos para ${INSTALL_DIR}..."
  install -d -m 755 "$INSTALL_DIR" "$INSTALL_DIR/state" "$INSTALL_DIR/logs"
  install -m 755 "$MONITOR_SOURCE" "$INSTALL_DIR/monitor.sh"
  install -m 644 "$ENV_EXAMPLE_SOURCE" "$INSTALL_DIR/.env.monitor.example"
  install -m 644 "$SYSTEMD_SOURCE" "$SERVICE_FILE"
}

write_env_file() {
  local bot_token=""
  local chat_id=""
  local host_label=""
  local check_interval=""
  local curl_timeout=""
  local ok_codes_regex=""
  local telegram_api_base=""
  local pm2_bin=""
  local pm2_home=""

  bot_token="$(choose_value "$(read_existing_value BOT_TOKEN)" "__SET_BOT_TOKEN__")"
  chat_id="$(choose_value "$(read_existing_value CHAT_ID)" "__SET_CHAT_ID__")"
  host_label="$(choose_value "$(read_existing_value HOST_LABEL)" "$DETECTED_HOST_LABEL")"
  check_interval="$(choose_value "$(read_existing_value CHECK_INTERVAL_SECONDS)" "10")"
  curl_timeout="$(choose_value "$(read_existing_value CURL_TIMEOUT_SECONDS)" "10")"
  ok_codes_regex="$(choose_value "$(read_existing_value HEALTH_OK_HTTP_CODES_REGEX)" "^(2|3)[0-9][0-9]$")"
  telegram_api_base="$(choose_value "$(read_existing_value TELEGRAM_API_BASE)" "https://api.telegram.org")"
  pm2_bin="$(choose_value "$(read_existing_value PM2_BIN)" "$DETECTED_PM2_BIN")"
  pm2_home="$(choose_value "$(read_existing_value PM2_HOME)" "$DETECTED_PM2_HOME")"

  log "Gerando ${ENV_FILE}..."
  cat > "$ENV_FILE" <<EOF
# Telegram
BOT_TOKEN=${bot_token}
CHAT_ID=${chat_id}

# Auto-derived by install.sh
PM2_NAME=${DETECTED_PM2_NAME}
SERVER_NAME=${DETECTED_SERVER_NAME}
HOST_LABEL=${host_label}
HEALTH_URL=${DETECTED_HEALTH_URL}

# PM2 runtime discovery
PM2_BIN=${pm2_bin}
PM2_HOME=${pm2_home}

# Monitor behavior
CHECK_INTERVAL_SECONDS=${check_interval}
CURL_TIMEOUT_SECONDS=${curl_timeout}
HEALTH_OK_HTTP_CODES_REGEX=${ok_codes_regex}
TELEGRAM_API_BASE=${telegram_api_base}

# Directories
STATE_DIR=${INSTALL_DIR}/state
LOG_DIR=${INSTALL_DIR}/logs
EOF

  chmod 640 "$ENV_FILE"
}

install_service() {
  log "Instalando servico systemd..."
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
}

print_summary() {
  log "Instalacao concluida."
  log "PM2_NAME=${DETECTED_PM2_NAME}"
  log "SERVER_NAME=${DETECTED_SERVER_NAME}"
  log "HEALTH_URL=${DETECTED_HEALTH_URL}"
  log "Arquivos instalados em ${INSTALL_DIR}"

  if [[ "$(read_existing_value BOT_TOKEN)" == "__SET_BOT_TOKEN__" || "$(read_existing_value CHAT_ID)" == "__SET_CHAT_ID__" ]]; then
    log "Ajuste BOT_TOKEN e CHAT_ID em ${ENV_FILE}, depois reinicie o servico."
  fi
}

main() {
  require_root
  ensure_source_files
  install_dependencies
  extend_pm2_path
  discover_pm2_bin
  guess_pm2_home
  discover_pm2_process
  derive_runtime_values
  install_project_files
  write_env_file
  install_service
  print_summary
}

main "$@"
