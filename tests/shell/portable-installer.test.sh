#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n install.sh scripts/deploy.sh
[ -x install.sh ] || fail "install.sh não é executável"
[ -x scripts/deploy.sh ] || fail "scripts/deploy.sh não é executável"
[ -x lowzicrm ] || fail "lowzicrm não é executável"

help="$(./lowzicrm help)"
printf '%s' "$help" | grep -q 'install' || fail "help sem install"
printf '%s' "$help" | grep -q 'doctor' || fail "help sem doctor"
printf '%s' "$help" | grep -q 'uninstall' || fail "help sem uninstall"

grep -q 'WeslleyMouraDev/LowziCRM.git' install.sh || fail "URL canônica ausente"
grep -q 'docker-compose.local.yml' scripts/deploy.sh || fail "modo local não usa override"
grep -q 'ghcr.io/weslleymouradev/lowzicrm:latest' scripts/deploy.sh || fail "imagem do app ausente"
grep -q 'lowzicrm-waha:2026.6.2-compat' scripts/deploy.sh || fail "fallback WAHA antigo ausente"
grep -q 'linux/amd64,linux/arm64' .github/workflows/publish-image.yml || fail "publicação multiarch ausente"

# O --env-file é dado não confiável: nunca pode executar substituição de comando.
sentinel="${TMPDIR:-/tmp}/lowzicrm-env-injection-$$"
tmp_env="${TMPDIR:-/tmp}/lowzicrm-env-test-$$"
rm -f "$sentinel"
printf "DEPLOY_MODE='local'\nDOMAIN='%s'\n" "\$(touch $sentinel)" > "$tmp_env"
(
  set -- help
  # shellcheck disable=SC1091
  source scripts/deploy.sh >/dev/null
  ENV_FILE="$tmp_env"
  unset DOMAIN
  load_env
  [ "$DOMAIN" = "\$(touch $sentinel)" ] || fail "valor dotenv foi alterado"
)
[ ! -e "$sentinel" ] || fail ".env executou comando arbitrário"

# `--yes` sozinho jamais apaga volumes; purge exige a flag dedicada.
mock_dir="${TMPDIR:-/tmp}/lowzicrm-docker-mock-$$"
mock_log="$mock_dir/docker.log"
mkdir -p "$mock_dir"
cat > "$mock_dir/docker" <<'MOCK'
#!/usr/bin/env bash
case " $* " in
  *" config --environment "*) printf '%s\n' "DEPLOY_MODE=local";;
  *) printf '%s\n' "$*" >> "$MOCK_LOG";;
esac
MOCK
chmod +x "$mock_dir/docker"
MOCK_LOG="$mock_log" PATH="$mock_dir:$PATH" ./scripts/deploy.sh uninstall --yes --env-file "$tmp_env" >/dev/null
if grep -q -- 'down -v' "$mock_log"; then fail "uninstall --yes apagaria volumes"; fi
grep -q -- 'down --remove-orphans' "$mock_log" || fail "uninstall não chamou compose down"
rm -rf "$mock_dir"
rm -f "$tmp_env" "$sentinel"

if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  fail ".env com segredos está rastreado pelo git"
fi

echo 'portable-installer: ok'
