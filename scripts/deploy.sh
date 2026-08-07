#!/usr/bin/env bash
# LowziCRM — instalador e CLI de operação portáteis.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMMAND="${1:-help}"
[ "$#" -gt 0 ] && shift
MODE="${LOWZICRM_MODE:-}"
YES=0
PURGE_DATA=0
ENV_FILE="${LOWZICRM_ENV_FILE:-.env}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:?Informe local ou public}"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --purge-data) PURGE_DATA=1; shift ;;
    --env-file) ENV_FILE="${2:?Informe o arquivo}"; shift 2 ;;
    --help|-h) COMMAND=help; shift ;;
    *) printf 'Opção desconhecida: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD='\033[1m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
else
  BOLD=''; GREEN=''; YELLOW=''; RED=''; RESET=''
fi
info() { printf "%b→%b %s\n" "$BOLD" "$RESET" "$*"; }
ok() { printf "%b✓%b %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%b!%b %s\n" "$YELLOW" "$RESET" "$*"; }
die() { printf "%b✗ %s%b\n" "$RED" "$*" "$RESET" >&2; exit 1; }

usage() {
  cat <<'EOF'
LowziCRM — instalador e CLI

Uso:
  ./install.sh [--mode local|public]
  ./lowzicrm <comando>

Comandos:
  install     Configura banco, imagens, administrador e inicia a stack
  update      Atualiza o código e as imagens, sem apagar dados
  status      Exibe o estado dos serviços
  logs        Acompanha os logs
  doctor      Valida host, configuração, containers e endpoint HTTP
  stop        Para os serviços sem apagar dados
  start       Inicia os serviços existentes
  uninstall   Remove containers sem apagar dados

Modos:
  local       Linux/macOS em http://localhost:3000
  public      VPS Linux com domínio, Caddy e HTTPS automático

Automação:
  OWNER_EMAIL=... OWNER_PASSWORD=... OWNER_ORG_NAME=... \
    ./install.sh --yes --mode public # usa um .env já preenchido

Remoção definitiva dos volumes:
  ./lowzicrm uninstall --purge-data
EOF
}

os_name() {
  case "$(uname -s)" in Linux) printf linux;; Darwin) printf macos;; *) printf unsupported;; esac
}

confirm() {
  [ "$YES" = 1 ] && return 0
  local answer
  printf '%s [s/N]: ' "$1"
  read -r answer </dev/tty || return 1
  case "$answer" in s|S|sim|SIM|y|Y|yes|YES) return 0;; *) return 1;; esac
}

need() { command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório ausente: $1"; }

docker_ready() { docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }

ensure_docker() {
  if docker_ready; then return 0; fi
  local os; os="$(os_name)"
  if command -v docker >/dev/null 2>&1; then
    if [ "$os" = macos ]; then
      open -a Docker >/dev/null 2>&1 || true
      info "Aguardando o Docker Desktop iniciar..."
      for _ in $(seq 1 60); do docker_ready && return 0; sleep 2; done
      die "Abra o Docker Desktop e execute novamente."
    fi
    die "Docker está instalado, mas o daemon não está acessível. No Linux, relogue após entrar no grupo docker ou execute com um usuário autorizado."
  fi

  if [ "$os" = macos ]; then
    command -v brew >/dev/null 2>&1 || die "Instale o Docker Desktop: https://docs.docker.com/desktop/setup/install/mac-install/"
    confirm "Docker Desktop não está instalado. Instalar com Homebrew?" || exit 1
    brew install --cask docker
    open -a Docker
    info "Conclua a autorização inicial do Docker Desktop; depois rode ./install.sh novamente."
    exit 0
  fi

  [ "$os" = linux ] || die "Sistema não suportado. Use Linux ou macOS."
  need curl
  confirm "Docker não está instalado. Instalar pelo script oficial get.docker.com?" || exit 1
  local installer="${TMPDIR:-/tmp}/get-docker.$$.sh"
  curl -fsSL https://get.docker.com -o "$installer"
  if [ "$(id -u)" -eq 0 ]; then sh "$installer"; else sudo sh "$installer"; fi
  rm -f "$installer"
  if [ "$(id -u)" -ne 0 ]; then
    sudo usermod -aG docker "$USER" || true
    warn "Seu usuário foi adicionado ao grupo docker. Execute 'newgrp docker' ou relogue e rode o instalador novamente."
  fi
  docker_ready || die "Docker instalado, mas a sessão atual ainda não tem acesso ao daemon."
}

random_hex() {
  openssl rand -hex "${1:-32}"
}

sha512() {
  if command -v sha512sum >/dev/null 2>&1; then printf %s "$1" | sha512sum | cut -d' ' -f1
  else printf %s "$1" | shasum -a 512 | cut -d' ' -f1
  fi
}

envq() {
  # Formato aceito tanto pelo Bash quanto pelo parser dotenv do Compose.
  # Aspas simples evitam expansão de $, backticks e espaços ao recarregar.
  local value="$2"
  value=${value//\'/\'\\\'\'}
  printf "%s='%s'\n" "$1" "$value"
}

set_env_value() {
  local key="$1" value="$2" tmp="${ENV_FILE}.tmp.$$"
  { grep -v "^${key}=" "$ENV_FILE" 2>/dev/null || true; envq "$key" "$value"; } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
  printf -v "$key" '%s' "$value"
  export "${key?}"
}

prompt() {
  local var="$1" label="$2" default="${3:-}" secret="${4:-0}" current="${!1:-}" value
  [ -n "$current" ] && return 0
  [ "$YES" = 1 ] && die "Falta $var no $ENV_FILE para instalação --yes."
  while [ -z "${value:-}" ]; do
    if [ "$secret" = 1 ]; then
      printf '%s%s: ' "$label" "${default:+ [$default]}"; read -r -s value </dev/tty; printf '\n'
    else
      printf '%s%s: ' "$label" "${default:+ [$default]}"; read -r value </dev/tty
    fi
    value="${value:-$default}"
  done
  printf -v "$var" '%s' "$value"
}

load_env() {
  [ -f "$ENV_FILE" ] || return 0
  # Parseia como dotenv com o Docker Compose; nunca executa o conteúdo no shell.
  # Substituições de comando, backticks e ponto-e-vírgula permanecem dados.
  local key value parsed
  parsed="$(LOWZICRM_ENV_FILE="$ENV_FILE" docker compose -f docker-compose.prod.yml --env-file "$ENV_FILE" config --environment)" \
    || die "Não foi possível interpretar $ENV_FILE como dotenv."
  while IFS='=' read -r key value; do
    case "$key" in
      APP_NAME|DEPLOY_MODE|NEXT_PUBLIC_APP_URL|DOMAIN|ACME_EMAIL|SUPABASE_URL|NEXT_PUBLIC_SUPABASE_URL|NEXT_PUBLIC_SUPABASE_ANON_KEY|SUPABASE_SERVICE_ROLE_KEY|SUPABASE_DB_URL|ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL|APP_IMAGE|WORKER_IMAGE|APP_PULL_POLICY|LOWZICRM_BUILD_LOCAL|WAHA_IMAGE|WAHA_API_KEY|WAHA_API_KEY_SHA512|REDIS_URL|ENCRYPTION_KEY|CREDENTIAL_ENCRYPTION_KEY|INTERNAL_SECRET|CRON_SECRET|IMPERSONATE_COOKIE_SECRET|SRH_TOKEN|WHATSAPP_DEFAULT_ENGINE|WHATSAPP_RUST_BRIDGE_FORCE_COMPAT)
        printf -v "$key" '%s' "$value"
        export "${key?}"
        ;;
    esac
  done <<< "$parsed"
}

compose_files() {
  printf '%s\n' -f docker-compose.prod.yml
  if [ "${LOWZICRM_BUILD_LOCAL:-false}" = true ]; then printf '%s\n' -f docker-compose.build.yml; fi
  if [ "${DEPLOY_MODE:-$MODE}" = local ]; then printf '%s\n' -f docker-compose.local.yml; fi
}

dc() {
  local args=()
  while IFS= read -r line; do args+=("$line"); done < <(compose_files)
  LOWZICRM_ENV_FILE="$ENV_FILE" docker compose "${args[@]}" --env-file "$ENV_FILE" "$@"
}

dc_build() {
  local args=(-f docker-compose.prod.yml -f docker-compose.build.yml)
  if [ "${DEPLOY_MODE:-$MODE}" = local ]; then args+=(-f docker-compose.local.yml); fi
  LOWZICRM_ENV_FILE="$ENV_FILE" docker compose "${args[@]}" --env-file "$ENV_FILE" "$@"
}

legacy_x86() {
  [ "$(uname -m)" = x86_64 ] || [ "$(uname -m)" = amd64 ] || return 1
  if [ "$(os_name)" = linux ]; then grep -qm1 -E '(^| )sse4_2( |$)' /proc/cpuinfo && return 1 || return 0; fi
  sysctl -n machdep.cpu.features 2>/dev/null | grep -q SSE4.2 && return 1 || return 0
}

validate_url() {
  case "$1" in https://*.supabase.co) return 0;; *) return 1;; esac
}

write_config() {
  local tmp="${ENV_FILE}.tmp.$$"
  umask 077
  {
    envq DEPLOY_MODE "$MODE"
    envq APP_NAME "$APP_NAME"
    envq DOMAIN "$DOMAIN"
    envq ACME_EMAIL "$ACME_EMAIL"
    envq NEXT_PUBLIC_APP_URL "$APP_URL"
    envq NEXT_PUBLIC_ADMIN_URL "$APP_URL"
    envq NEXT_PUBLIC_SUPABASE_URL "$NEXT_PUBLIC_SUPABASE_URL"
    envq NEXT_PUBLIC_SUPABASE_ANON_KEY "$NEXT_PUBLIC_SUPABASE_ANON_KEY"
    envq SUPABASE_SERVICE_ROLE_KEY "$SUPABASE_SERVICE_ROLE_KEY"
    envq SUPABASE_DB_URL "$SUPABASE_DB_URL"
    envq ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
    envq ANTHROPIC_BASE_URL "https://api.minimax.io/anthropic"
    envq APP_IMAGE "ghcr.io/weslleymouradev/lowzicrm:latest"
    envq WORKER_IMAGE "ghcr.io/weslleymouradev/lowzicrm-worker:latest"
    envq APP_PULL_POLICY "always"
    envq LOWZICRM_BUILD_LOCAL "false"
    envq WAHA_IMAGE "$WAHA_IMAGE"
    envq WHATSAPP_DEFAULT_ENGINE "WEBJS"
    envq WHATSAPP_RUST_BRIDGE_FORCE_COMPAT "$WHATSAPP_RUST_BRIDGE_FORCE_COMPAT"
    envq WAHA_API_BASE_URL "http://waha:3000"
    envq WAHA_API_KEY "$WAHA_API_KEY"
    envq WAHA_API_KEY_SHA512 "$(sha512 "$WAHA_API_KEY")"
    envq WAHA_HMAC_SECRET "$WAHA_HMAC_SECRET"
    envq WAHA_WEBHOOK_BASE_URL "$APP_URL"
    envq WAHA_WEBHOOK_REQUIRE_SIGNATURE "false"
    envq INTERNAL_SECRET "$INTERNAL_SECRET"
    envq INTERNAL_CRON_SECRET "$INTERNAL_SECRET"
    envq SRH_TOKEN "$SRH_TOKEN"
    envq UPSTASH_REDIS_REST_URL "http://srh:80"
    envq UPSTASH_REDIS_REST_TOKEN "$SRH_TOKEN"
    envq CPF_ENCRYPTION_KEY "$CPF_ENCRYPTION_KEY"
    envq NUVEMSHOP_OAUTH_ENCRYPTION_KEY "$NUVEMSHOP_OAUTH_ENCRYPTION_KEY"
    envq WAHA_BYO_ENCRYPTION_KEY "$WAHA_BYO_ENCRYPTION_KEY"
    envq AI_CRED_AES_KEY "$AI_CRED_AES_KEY"
    envq IMPERSONATE_COOKIE_SECRET "$IMPERSONATE_COOKIE_SECRET"
    envq LGPD_SIGNING_KEY "$LGPD_SIGNING_KEY"
    envq EVENT_LOG_WORKER_ENABLED "true"
    envq AGENT_DISPATCH_CONSUMER "engine"
    envq NUVEMSHOP_ENABLED "false"
    envq SENTRY_DSN ""
    envq OPENAI_API_KEY ""
    envq AI_GATEWAY_API_KEY ""
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

collect_config() {
  load_env
  if [ -z "$MODE" ]; then [ "$(os_name)" = macos ] && MODE=local || MODE=public; fi
  case "$MODE" in local|public) :;; *) die "Modo inválido: $MODE (use local ou public).";; esac
  [ "$MODE" != public ] || [ "$(os_name)" = linux ] || die "Modo public é destinado a VPS Linux. No macOS use --mode local."

  prompt APP_NAME "Nome da instalação" "LowziCRM"
  if [ "$MODE" = public ]; then
    prompt DOMAIN "Domínio, sem https://"
    prompt ACME_EMAIL "E-mail para o certificado TLS"
    APP_URL="https://$DOMAIN"
  else
    DOMAIN="localhost"; ACME_EMAIL="local@localhost"; APP_URL="http://localhost:3000"
  fi
  prompt NEXT_PUBLIC_SUPABASE_URL "URL do projeto Supabase"
  validate_url "$NEXT_PUBLIC_SUPABASE_URL" || die "URL Supabase inválida. Exemplo: https://projeto.supabase.co"
  prompt NEXT_PUBLIC_SUPABASE_ANON_KEY "Supabase anon/publishable key" "" 1
  prompt SUPABASE_SERVICE_ROLE_KEY "Supabase service role/secret key" "" 1
  prompt SUPABASE_DB_URL "Supabase Database URI (use o pooler IPv4)" "" 1
  prompt ANTHROPIC_API_KEY "Chave da API MiniMax" "" 1
  prompt OWNER_EMAIL "E-mail do primeiro administrador"
  prompt OWNER_PASSWORD "Senha inicial do administrador (mínimo 8 caracteres)" "" 1
  [ "${#OWNER_PASSWORD}" -ge 8 ] || die "A senha precisa ter pelo menos 8 caracteres."
  prompt OWNER_ORG_NAME "Nome da empresa" "$APP_NAME"

  WAHA_API_KEY="${WAHA_API_KEY:-$(random_hex 32)}"
  WAHA_HMAC_SECRET="${WAHA_HMAC_SECRET:-$(random_hex 32)}"
  INTERNAL_SECRET="${INTERNAL_SECRET:-$(random_hex 32)}"
  SRH_TOKEN="${SRH_TOKEN:-$(random_hex 32)}"
  CPF_ENCRYPTION_KEY="${CPF_ENCRYPTION_KEY:-$(random_hex 32)}"
  NUVEMSHOP_OAUTH_ENCRYPTION_KEY="${NUVEMSHOP_OAUTH_ENCRYPTION_KEY:-$(random_hex 32)}"
  WAHA_BYO_ENCRYPTION_KEY="${WAHA_BYO_ENCRYPTION_KEY:-$(random_hex 32)}"
  AI_CRED_AES_KEY="${AI_CRED_AES_KEY:-$(openssl rand -base64 32)}"
  IMPERSONATE_COOKIE_SECRET="${IMPERSONATE_COOKIE_SECRET:-$(random_hex 32)}"
  LGPD_SIGNING_KEY="${LGPD_SIGNING_KEY:-$(random_hex 32)}"

  if [ -z "${WAHA_IMAGE:-}" ]; then
    if legacy_x86; then
      WAHA_IMAGE="ghcr.io/weslleymouradev/lowzicrm-waha:2026.6.2-compat"
      WHATSAPP_RUST_BRIDGE_FORCE_COMPAT=1
      warn "CPU x86 antiga detectada: usando WAHA recompilado sem SIMD."
    else
      WAHA_IMAGE="mirror.gcr.io/devlikeapro/waha:chrome-2026.6.2"
      WHATSAPP_RUST_BRIDGE_FORCE_COMPAT=0
    fi
  fi
  write_config
  ok "Configuração salva em $ENV_FILE (permissão 600)."
}

apply_schema() {
  info "Validando a conexão PostgreSQL..."
  docker run --rm postgres:17-alpine psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -tAc 'select 1' >/dev/null
  local exists
  exists="$(docker run --rm postgres:17-alpine psql "$SUPABASE_DB_URL" -tAc "select to_regclass('public.organizations') is not null" | tr -d '[:space:]')"
  if [ "$exists" = t ]; then
    info "Schema existente: aplicando somente o apêndice compatível de atualização..."
    local log="$ROOT/baseline-apply.log"
    docker run --rm -i -v "$ROOT/supabase/baseline.sql:/baseline.sql:ro" postgres:17-alpine \
      psql "$SUPABASE_DB_URL" -q -f /baseline.sql >"$log" 2>&1 || true
    local unexpected
    unexpected="$(grep -iE 'ERROR|FATAL' "$log" | grep -viE 'already exists|multiple primary keys|multiple default values|is already a member|already a partition' || true)"
    [ -z "$unexpected" ] || { printf '%s\n' "$unexpected" | tail -20 >&2; die "Atualização do schema encontrou erros inesperados. Veja $log"; }
    ok "Schema existente atualizado."
    return 0
  fi
  info "Aplicando o schema inicial no Supabase..."
  docker run --rm postgres:17-alpine psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -c \
    'create extension if not exists vector with schema public; create extension if not exists citext with schema public; create extension if not exists pg_trgm with schema public;' >/dev/null
  docker run --rm -i -v "$ROOT/supabase/baseline.sql:/baseline.sql:ro" postgres:17-alpine \
    psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /baseline.sql >/dev/null
  ok "Schema inicial aplicado."
}

wait_app() {
  info "Aguardando o LowziCRM responder..."
  local app_url="${APP_URL:-${NEXT_PUBLIC_APP_URL:-http://localhost:3000}}"
  local url="$app_url/api/v1/health"
  [ "$MODE" = local ] && url="http://127.0.0.1:3000/api/v1/health"
  for _ in $(seq 1 90); do
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then ok "Aplicação saudável: $app_url"; return 0; fi
    sleep 3
  done
  dc logs --tail=80 app waha
  die "A aplicação não ficou saudável dentro do tempo esperado."
}

bootstrap_owner() {
  info "Criando ou atualizando o primeiro administrador..."
  dc run --rm --no-deps \
    -e OWNER_EMAIL="$OWNER_EMAIL" -e OWNER_PASSWORD="$OWNER_PASSWORD" -e OWNER_ORG_NAME="$OWNER_ORG_NAME" \
    worker pnpm exec tsx scripts/bootstrap-owner.ts
  unset OWNER_PASSWORD
}

pull_or_build() {
  if [ "${LOWZICRM_BUILD_LOCAL:-false}" = true ]; then
    info "Instalação configurada para build local; reconstruindo app e worker."
    dc build app worker
    case "${WAHA_IMAGE:-}" in
      ghcr.io/weslleymouradev/lowzicrm-waha:*)
        docker build -f Dockerfile.waha-compat -t "$WAHA_IMAGE" .;;
    esac
    LOWZICRM_LOCAL_BUILD=1
    return 0
  fi
  if dc pull; then return 0; fi
  warn "Não foi possível baixar alguma imagem pronta; usando build local como fallback."
  dc_build build app worker
  case "${WAHA_IMAGE:-}" in
    ghcr.io/weslleymouradev/lowzicrm-waha:*)
      docker build -f Dockerfile.waha-compat -t "$WAHA_IMAGE" .;;
  esac
  set_env_value LOWZICRM_BUILD_LOCAL true
  LOWZICRM_LOCAL_BUILD=1
}

install_cmd() {
  need openssl; need curl
  ensure_docker
  collect_config
  load_env
  apply_schema
  info "Baixando imagens prontas..."
  pull_or_build
  info "Iniciando os serviços..."
  if [ "${LOWZICRM_LOCAL_BUILD:-0}" = 1 ]; then dc_build up -d; else dc up -d; fi
  bootstrap_owner
  wait_app
  cat > lowzicrm <<'EOF'
#!/usr/bin/env bash
set -e
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
exec "$ROOT/scripts/deploy.sh" "$@"
EOF
  chmod +x lowzicrm
  printf '\n%bLowziCRM instalado.%b\n  URL: %s\n  Comandos: ./lowzicrm status | logs | update | doctor\n' "$GREEN" "$RESET" "$APP_URL"
}

update_cmd() {
  ensure_docker; load_env; [ -f "$ENV_FILE" ] || die "Execute ./install.sh primeiro."
  if git diff --quiet && git diff --cached --quiet; then git pull --ff-only; else warn "Alterações locais detectadas; código não foi atualizado."; fi
  apply_schema
  pull_or_build
  if [ "${LOWZICRM_LOCAL_BUILD:-0}" = 1 ]; then dc_build up -d --remove-orphans; else dc up -d --remove-orphans; fi
  wait_app
}

status_cmd() { ensure_docker; load_env; dc ps; }
logs_cmd() { ensure_docker; load_env; dc logs -f --tail=150; }
start_cmd() { ensure_docker; load_env; dc up -d; }
stop_cmd() { ensure_docker; load_env; dc stop; }

doctor_cmd() {
  printf 'OS: %s (%s)\n' "$(os_name)" "$(uname -m)"
  if docker_ready; then ok "Docker e Compose acessíveis"; else die "Docker indisponível"; fi
  if [ -f "$ENV_FILE" ]; then ok "$ENV_FILE existe"; else die "$ENV_FILE ausente"; fi
  load_env
  dc config --quiet && ok "Compose válido"
  dc ps
  local url="${NEXT_PUBLIC_APP_URL:-http://127.0.0.1:3000}/api/v1/health"
  if curl -fsS --max-time 15 "$url" >/dev/null; then ok "Health HTTP respondeu"; else die "Health HTTP falhou: $url"; fi
}

uninstall_cmd() {
  ensure_docker; load_env
  dc down --remove-orphans
  if [ "$PURGE_DATA" = 1 ] && confirm "Remover DEFINITIVAMENTE todos os volumes locais (sessões WhatsApp e certificados)?"; then
    dc down -v --remove-orphans
    ok "Volumes removidos. O projeto Supabase externo não foi apagado."
  else
    ok "Containers removidos; volumes preservados. Para apagá-los: ./lowzicrm uninstall --purge-data"
  fi
}

case "$COMMAND" in
  install) install_cmd;; update) update_cmd;; status) status_cmd;; logs) logs_cmd;; doctor) doctor_cmd;;
  start) start_cmd;; stop) stop_cmd;; uninstall) uninstall_cmd;; help) usage;;
  *) usage; exit 2;;
esac
