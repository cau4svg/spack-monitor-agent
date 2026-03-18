#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL_DEFAULT="https://github.com/cau4svg/spack-monitor-agent.git"
BRANCH_DEFAULT="main"
CHECKOUT_DIR_DEFAULT="/usr/local/src/spack-monitor-agent"

REPO_URL="${REPO_URL:-$REPO_URL_DEFAULT}"
BRANCH="${BRANCH:-$BRANCH_DEFAULT}"
CHECKOUT_DIR="${CHECKOUT_DIR:-$CHECKOUT_DIR_DEFAULT}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERRO: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Uso:
  sudo bash bootstrap-install.sh [--repo URL] [--branch NOME] [--dir CAMINHO]

Opcoes:
  --repo URL     URL do repositorio git a ser clonado/atualizado.
  --branch NOME  Branch a ser usada no checkout.
  --dir CAMINHO  Diretorio local onde o repositorio sera mantido.
  -h, --help     Exibe esta ajuda.

Variaveis de ambiente equivalentes:
  REPO_URL
  BRANCH
  CHECKOUT_DIR
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Execute como root. Exemplo: sudo bash bootstrap-install.sh"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || fail "Faltou valor para --repo"
        REPO_URL="$2"
        shift 2
        ;;
      --repo=*)
        REPO_URL="${1#*=}"
        shift
        ;;
      --branch)
        [[ $# -ge 2 ]] || fail "Faltou valor para --branch"
        BRANCH="$2"
        shift 2
        ;;
      --branch=*)
        BRANCH="${1#*=}"
        shift
        ;;
      --dir)
        [[ $# -ge 2 ]] || fail "Faltou valor para --dir"
        CHECKOUT_DIR="$2"
        shift 2
        ;;
      --dir=*)
        CHECKOUT_DIR="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Parametro invalido: $1"
        ;;
    esac
  done
}

ensure_git() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    fail "git nao encontrado e apt-get nao esta disponivel para instalacao automatica."
  fi

  export DEBIAN_FRONTEND=noninteractive
  log "Instalando git e certificados..."
  apt-get update
  apt-get install -y git ca-certificates
}

validate_checkout_dir() {
  if [[ -e "$CHECKOUT_DIR" && ! -d "$CHECKOUT_DIR" ]]; then
    fail "O caminho ${CHECKOUT_DIR} existe, mas nao e um diretorio."
  fi
}

clone_repo() {
  local parent_dir=""

  parent_dir="$(dirname "$CHECKOUT_DIR")"
  install -d -m 755 "$parent_dir"

  log "Clonando ${REPO_URL} em ${CHECKOUT_DIR}..."
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$CHECKOUT_DIR"
}

update_repo() {
  local current_remote=""

  current_remote="$(git -C "$CHECKOUT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$current_remote" && "$current_remote" != "$REPO_URL" ]]; then
    fail "Repositorio existente em ${CHECKOUT_DIR} usa origin=${current_remote}. Ajuste --repo ou limpe o diretorio manualmente."
  fi

  log "Atualizando repositorio em ${CHECKOUT_DIR}..."
  git -C "$CHECKOUT_DIR" fetch --prune origin

  if git -C "$CHECKOUT_DIR" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    git -C "$CHECKOUT_DIR" checkout "$BRANCH"
  else
    git -C "$CHECKOUT_DIR" checkout -b "$BRANCH" --track "origin/${BRANCH}"
  fi

  git -C "$CHECKOUT_DIR" pull --ff-only origin "$BRANCH"
}

sync_repo() {
  if [[ -d "${CHECKOUT_DIR}/.git" ]]; then
    update_repo
    return 0
  fi

  if [[ -d "$CHECKOUT_DIR" ]]; then
    fail "O diretorio ${CHECKOUT_DIR} ja existe, mas nao e um repositorio git."
  fi

  clone_repo
}

run_install() {
  local install_script="${CHECKOUT_DIR}/install.sh"

  [[ -f "$install_script" ]] || fail "Arquivo ausente: ${install_script}"

  log "Executando ${install_script}..."
  bash "$install_script"
}

print_summary() {
  log "Bootstrap concluido."
  log "Repositorio: ${REPO_URL}"
  log "Branch: ${BRANCH}"
  log "Checkout local: ${CHECKOUT_DIR}"
}

main() {
  parse_args "$@"
  require_root
  validate_checkout_dir
  ensure_git
  sync_repo
  run_install
  print_summary
}

main "$@"
