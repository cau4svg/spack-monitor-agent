#!/usr/bin/env bash
set -uo pipefail

export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env.monitor}"
DEFAULT_INSTALL_DIR="/opt/spack-monitor"
RUNNING=1
PM2_CMD=""
PM2_STATUS="unknown"
PID="0"
CPU_PCT="0.0%"
MEMORY_MB="0.0mb"
RESTART_COUNT="0"
RESTART_COUNT_VALID=0
URL_STATUS="down"
HTTP_CODE="000"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_line() {
  local level="$1"
  shift
  local message="$*"
  local line="[$(timestamp)] [$level] $message"

  printf '%s\n' "$line"

  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

log_info() {
  log_line INFO "$*"
}

log_warn() {
  log_line WARN "$*"
}

log_error() {
  log_line ERROR "$*"
}

html_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g'
}

sanitize_positive_int() {
  local value="$1"
  local fallback="$2"

  if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -gt 0 ]]; then
    printf '%s' "$value"
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

extend_runtime_path() {
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

load_configuration() {
  if [[ ! -f "$ENV_FILE" ]]; then
    log_error "Arquivo de configuracao ausente: $ENV_FILE"
    return 1
  fi

  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a

  CHECK_INTERVAL_SECONDS="$(sanitize_positive_int "${CHECK_INTERVAL_SECONDS:-10}" "10")"
  CURL_TIMEOUT_SECONDS="$(sanitize_positive_int "${CURL_TIMEOUT_SECONDS:-10}" "10")"
  HEALTH_OK_HTTP_CODES_REGEX="${HEALTH_OK_HTTP_CODES_REGEX:-^(2|3)[0-9][0-9]$}"
  TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"
  STATE_DIR="${STATE_DIR:-${DEFAULT_INSTALL_DIR}/state}"
  LOG_DIR="${LOG_DIR:-${DEFAULT_INSTALL_DIR}/logs}"
  HOST_LABEL="${HOST_LABEL:-$(hostname -s 2>/dev/null || hostname)}"
  BOT_TOKEN="${BOT_TOKEN:-}"
  CHAT_ID="${CHAT_ID:-}"
  PM2_NAME="${PM2_NAME:-}"
  SERVER_NAME="${SERVER_NAME:-}"
  HEALTH_URL="${HEALTH_URL:-}"
  PM2_BIN="${PM2_BIN:-}"
  PM2_HOME="${PM2_HOME:-}"
  LOG_FILE="${LOG_DIR}/monitor.log"

  mkdir -p "$STATE_DIR" "$LOG_DIR"
  touch "$LOG_FILE" 2>/dev/null || true
  extend_runtime_path

  if [[ -z "$PM2_NAME" || -z "$SERVER_NAME" || -z "$HEALTH_URL" ]]; then
    log_error "PM2_NAME, SERVER_NAME e HEALTH_URL precisam estar definidos em $ENV_FILE"
    return 1
  fi

  return 0
}

discover_pm2_bin() {
  local candidate=""

  if [[ -n "${PM2_BIN:-}" && -x "$PM2_BIN" ]]; then
    printf '%s\n' "$PM2_BIN"
    return 0
  fi

  if command -v pm2 >/dev/null 2>&1; then
    command -v pm2
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
      printf '%s\n' "$candidate"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  return 1
}

ensure_pm2_command() {
  if [[ -n "${PM2_HOME:-}" ]]; then
    export PM2_HOME
  fi

  if [[ -n "$PM2_CMD" && -x "$PM2_CMD" ]]; then
    return 0
  fi

  PM2_CMD="$(discover_pm2_bin 2>/dev/null || true)"
  [[ -n "$PM2_CMD" ]]
}

extract_pm2_field() {
  local field="$1"
  local content="$2"

  printf '%s\n' "$content" | awk -v wanted="$field" -F '[│|]' '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }

    {
      if (NF >= 3) {
        key = tolower(trim($2))
        value = trim($3)
        if (key == tolower(wanted)) {
          print value
          exit
        }
      }
    }
  '
}

collect_process_metrics() {
  local show_output=""
  local restarts_raw=""
  local stats=""
  local cpu_raw=""
  local rss_kb=""

  PM2_STATUS="unknown"
  PID="0"
  CPU_PCT="0.0%"
  MEMORY_MB="0.0mb"
  RESTART_COUNT="0"
  RESTART_COUNT_VALID=0

  if ! ensure_pm2_command; then
    PM2_STATUS="pm2_not_found"
    return 1
  fi

  show_output="$("$PM2_CMD" show "$PM2_NAME" --no-color 2>/dev/null || true)"
  if [[ -n "$show_output" ]]; then
    PM2_STATUS="$(extract_pm2_field "status" "$show_output")"
    restarts_raw="$(extract_pm2_field "restarts" "$show_output")"
  fi

  [[ -n "$PM2_STATUS" ]] || PM2_STATUS="unknown"

  restarts_raw="$(printf '%s' "$restarts_raw" | tr -cd '0-9')"
  if [[ -n "$restarts_raw" ]]; then
    RESTART_COUNT="$restarts_raw"
    RESTART_COUNT_VALID=1
  fi

  PID="$("$PM2_CMD" pid "$PM2_NAME" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if [[ ! "$PID" =~ ^[0-9]+$ ]]; then
    PID="0"
  fi

  if [[ "$PID" -gt 0 ]] && ps -p "$PID" >/dev/null 2>&1; then
    stats="$(ps -p "$PID" -o %cpu= -o rss= 2>/dev/null | awk 'NR == 1 { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $1 " " $2 }')"
    read -r cpu_raw rss_kb <<< "$stats"

    if [[ -n "${cpu_raw:-}" ]]; then
      CPU_PCT="$(awk -v value="$cpu_raw" 'BEGIN { printf "%.1f%%", value + 0 }')"
    fi

    if [[ -n "${rss_kb:-}" ]]; then
      MEMORY_MB="$(awk -v value="$rss_kb" 'BEGIN { printf "%.1fmb", value / 1024 }')"
    fi
  fi

  return 0
}

check_health_url() {
  local code=""

  HTTP_CODE="000"
  URL_STATUS="down"

  if [[ -z "$HEALTH_URL" ]]; then
    return 1
  fi

  code="$(curl -sS -L -X GET --max-time "$CURL_TIMEOUT_SECONDS" -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || true)"
  HTTP_CODE="${code:-000}"

  if [[ "$HTTP_CODE" =~ $HEALTH_OK_HTTP_CODES_REGEX ]]; then
    URL_STATUS="up"
  fi
}

read_state() {
  local name="$1"
  local path="${STATE_DIR}/${name}"

  if [[ -f "$path" ]]; then
    tr -d '\r\n' < "$path"
  fi
}

write_state() {
  local name="$1"
  local value="$2"

  printf '%s\n' "$value" > "${STATE_DIR}/${name}"
}

telegram_ready() {
  [[ -n "$BOT_TOKEN" ]] &&
  [[ -n "$CHAT_ID" ]] &&
  [[ "$BOT_TOKEN" != "__SET_BOT_TOKEN__" ]] &&
  [[ "$CHAT_ID" != "__SET_CHAT_ID__" ]]
}

send_telegram_message() {
  local message="$1"
  local endpoint=""

  if ! telegram_ready; then
    log_warn "BOT_TOKEN/CHAT_ID nao configurados; alerta ignorado."
    return 0
  fi

  endpoint="${TELEGRAM_API_BASE%/}/bot${BOT_TOKEN}/sendMessage"

  if ! curl -sS --max-time 20 -X POST "$endpoint" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${message}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" \
    -o /dev/null; then
    log_warn "Falha ao enviar alerta para o Telegram."
    return 1
  fi

  return 0
}

is_online_status() {
  local status="$1"
  [[ "${status,,}" == "online" ]]
}

build_restart_message() {
  local previous_restarts="$1"

  printf '⚠️ PROCESSO REINICIADO\nServidor: %s\nHost: %s\nProcesso: %s\nPID: %s\nStatus PM2: %s\nCPU: %s\nMemoria: %s\nRestarts: %s -> %s' \
    "$(html_escape "$SERVER_NAME")" \
    "$(html_escape "$HOST_LABEL")" \
    "$(html_escape "$PM2_NAME")" \
    "$(html_escape "$PID")" \
    "$(html_escape "$PM2_STATUS")" \
    "$(html_escape "$CPU_PCT")" \
    "$(html_escape "$MEMORY_MB")" \
    "$(html_escape "$previous_restarts")" \
    "$(html_escape "$RESTART_COUNT")"
}

build_process_down_message() {
  printf '❌ PROCESSO PM2 FORA DO AR\nServidor: %s\nHost: %s\nProcesso: %s\nPID: %s\nStatus PM2: %s\nCPU: %s\nMemoria: %s\nRestarts: %s' \
    "$(html_escape "$SERVER_NAME")" \
    "$(html_escape "$HOST_LABEL")" \
    "$(html_escape "$PM2_NAME")" \
    "$(html_escape "$PID")" \
    "$(html_escape "$PM2_STATUS")" \
    "$(html_escape "$CPU_PCT")" \
    "$(html_escape "$MEMORY_MB")" \
    "$(html_escape "$RESTART_COUNT")"
}

build_process_up_message() {
  printf '✅ PROCESSO PM2 RECUPERADO\nServidor: %s\nHost: %s\nProcesso: %s\nPID: %s\nStatus PM2: %s\nCPU: %s\nMemoria: %s\nRestarts: %s' \
    "$(html_escape "$SERVER_NAME")" \
    "$(html_escape "$HOST_LABEL")" \
    "$(html_escape "$PM2_NAME")" \
    "$(html_escape "$PID")" \
    "$(html_escape "$PM2_STATUS")" \
    "$(html_escape "$CPU_PCT")" \
    "$(html_escape "$MEMORY_MB")" \
    "$(html_escape "$RESTART_COUNT")"
}

build_url_down_message() {
  printf '❌ URL INDISPONIVEL\nServidor: %s\nHost: %s\nURL: %s\nHTTP: %s\nProcesso: %s\nStatus PM2: %s' \
    "$(html_escape "$SERVER_NAME")" \
    "$(html_escape "$HOST_LABEL")" \
    "$(html_escape "$HEALTH_URL")" \
    "$(html_escape "$HTTP_CODE")" \
    "$(html_escape "$PM2_NAME")" \
    "$(html_escape "$PM2_STATUS")"
}

build_url_up_message() {
  printf '✅ URL NORMALIZADA\nServidor: %s\nHost: %s\nURL: %s\nHTTP: %s\nProcesso: %s\nStatus PM2: %s' \
    "$(html_escape "$SERVER_NAME")" \
    "$(html_escape "$HOST_LABEL")" \
    "$(html_escape "$HEALTH_URL")" \
    "$(html_escape "$HTTP_CODE")" \
    "$(html_escape "$PM2_NAME")" \
    "$(html_escape "$PM2_STATUS")"
}

handle_process_transition() {
  local previous_status=""

  previous_status="$(read_state "pm2_status")"
  if [[ -z "$previous_status" ]]; then
    write_state "pm2_status" "$PM2_STATUS"
    log_info "Estado inicial PM2 registrado: ${PM2_STATUS}"
    return 0
  fi

  if is_online_status "$previous_status" && ! is_online_status "$PM2_STATUS"; then
    log_warn "Processo PM2 caiu: ${PM2_NAME} (${previous_status} -> ${PM2_STATUS})"
    send_telegram_message "$(build_process_down_message)" || true
  elif ! is_online_status "$previous_status" && is_online_status "$PM2_STATUS"; then
    log_info "Processo PM2 recuperado: ${PM2_NAME} (${previous_status} -> ${PM2_STATUS})"
    send_telegram_message "$(build_process_up_message)" || true
  fi

  write_state "pm2_status" "$PM2_STATUS"
}

handle_restart_transition() {
  local previous_restarts=""

  if [[ "$RESTART_COUNT_VALID" -ne 1 ]]; then
    return 0
  fi

  previous_restarts="$(read_state "restart_count")"
  if [[ -z "$previous_restarts" ]]; then
    write_state "restart_count" "$RESTART_COUNT"
    log_info "Estado inicial de restarts registrado: ${RESTART_COUNT}"
    return 0
  fi

  if [[ "$previous_restarts" != "$RESTART_COUNT" ]]; then
    log_warn "Contador de restart mudou: ${previous_restarts} -> ${RESTART_COUNT}"
    send_telegram_message "$(build_restart_message "$previous_restarts")" || true
  fi

  write_state "restart_count" "$RESTART_COUNT"
}

handle_url_transition() {
  local previous_url_status=""

  previous_url_status="$(read_state "url_status")"
  if [[ -z "$previous_url_status" ]]; then
    write_state "url_status" "$URL_STATUS"
    log_info "Estado inicial da URL registrado: ${URL_STATUS} (HTTP ${HTTP_CODE})"
    return 0
  fi

  if [[ "$previous_url_status" == "up" && "$URL_STATUS" != "up" ]]; then
    log_warn "URL indisponivel: ${HEALTH_URL} (HTTP ${HTTP_CODE})"
    send_telegram_message "$(build_url_down_message)" || true
  elif [[ "$previous_url_status" != "up" && "$URL_STATUS" == "up" ]]; then
    log_info "URL recuperada: ${HEALTH_URL} (HTTP ${HTTP_CODE})"
    send_telegram_message "$(build_url_up_message)" || true
  fi

  write_state "url_status" "$URL_STATUS"
}

sleep_with_shutdown() {
  local remaining="$1"

  while [[ "$remaining" -gt 0 ]]; do
    [[ "$RUNNING" -eq 1 ]] || return 0
    sleep 1
    remaining=$((remaining - 1))
  done
}

graceful_shutdown() {
  RUNNING=0
  log_info "Encerrando Spack Monitor."
}

run_cycle() {
  collect_process_metrics || true
  check_health_url || true
  handle_process_transition
  handle_restart_transition
  handle_url_transition
}

main() {
  trap graceful_shutdown INT TERM

  load_configuration || exit 1
  log_info "Spack Monitor iniciado para ${SERVER_NAME} (${PM2_NAME})"

  while [[ "$RUNNING" -eq 1 ]]; do
    run_cycle
    sleep_with_shutdown "$CHECK_INTERVAL_SECONDS"
  done
}

main "$@"
