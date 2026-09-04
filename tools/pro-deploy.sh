#!/usr/bin/env bash
# 按不可变镜像摘要部署 Pro；默认仅校验参数，传入 --execute 才连接服务器。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CUSTOMIZATIONS="${REPO_ROOT}/deploy/pro/customizations.yaml"
OVERRIDE_FILE="${REPO_ROOT}/deploy/pro/compose.image-override.yaml"
RELEASE_MANIFEST="${REPO_ROOT}/build/pro-release-manifest.json"
IMAGE=""
EXECUTE=false
ALLOW_MIGRATIONS=false

usage() {
  cat <<'EOF'
用法：tools/pro-deploy.sh --image <ghcr.io/...@sha256:...> [选项]

选项：
  --manifest <path>       指定 release-manifest.json
  --allow-migrations      明确允许包含数据库迁移的发布
  --execute               执行 SSH 部署；缺省只显示检查结果
  --help                  显示帮助
EOF
}

fail() {
  echo "[pro-deploy] FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:-}"; shift 2 ;;
    --manifest) RELEASE_MANIFEST="${2:-}"; shift 2 ;;
    --allow-migrations) ALLOW_MIGRATIONS=true; shift ;;
    --execute) EXECUTE=true; shift ;;
    --help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "缺少 jq"
[[ -f "${CUSTOMIZATIONS}" ]] || fail "缺少 Pro 二开清单"
[[ -f "${OVERRIDE_FILE}" ]] || fail "缺少 Compose 镜像覆盖文件"
[[ -f "${RELEASE_MANIFEST}" ]] || fail "发布清单不存在: ${RELEASE_MANIFEST}"
[[ "${IMAGE}" =~ ^ghcr\.io/aether-shell/rootflowtokenrouter@sha256:[0-9a-f]{64}$ ]] || \
  fail "镜像必须使用 Pro GHCR 的不可变 sha256 摘要"

HOST="$(jq -r '.runtime_contract.ssh_host' "${CUSTOMIZATIONS}")"
SSH_USER="$(jq -r '.runtime_contract.ssh_user' "${CUSTOMIZATIONS}")"
COMPOSE_FILE="$(jq -r '.runtime_contract.compose_file' "${CUSTOMIZATIONS}")"
REMOTE_OVERRIDE="$(jq -r '.runtime_contract.compose_override_file' "${CUSTOMIZATIONS}")"
APP_CONTAINER="$(jq -r '.runtime_contract.app_container' "${CUSTOMIZATIONS}")"
DB_CONTAINER="$(jq -r '.runtime_contract.database_container' "${CUSTOMIZATIONS}")"
BASE_URL="$(jq -r '.runtime_contract.public_base_url' "${CUSTOMIZATIONS}")"
HEALTH_PATH="$(jq -r '.runtime_contract.health_path' "${CUSTOMIZATIONS}")"
EXPECTED_COMMIT="$(jq -r '.source.commit // empty' "${RELEASE_MANIFEST}")"
PRODUCT="$(jq -r '.product // empty' "${RELEASE_MANIFEST}")"
MANIFEST_IMAGE="$(jq -r '.image.reference // empty' "${RELEASE_MANIFEST}")"
DATABASE_CHANGE_COUNT="$(jq '(.changed_database_paths // .changed_migrations) | length' "${RELEASE_MANIFEST}")"
AUTO_ROLLBACK="$(jq -r '.automatic_app_rollback_allowed' "${RELEASE_MANIFEST}")"
MARKER_REGEX="$(jq -r '[.customizations[] | .binary_markers[]?] | join("|")' "${CUSTOMIZATIONS}")"

[[ "${HOST}" == "67.21.68.75" ]] || fail "目标不是固定 Pro 主机"
[[ "${SSH_USER}" == "root" ]] || fail "SSH 用户不是 Pro 约定用户"
[[ "${COMPOSE_FILE}" == "/opt/tokenrouter-pro/compose.yaml" ]] || fail "Compose 路径不是 Pro"
[[ "${APP_CONTAINER}" == "tokenrouter-pro-app" ]] || fail "应用容器不是 Pro"
[[ "${DB_CONTAINER}" == "tokenrouter-pro-postgres" ]] || fail "数据库容器不是 Pro"
[[ "${BASE_URL}" == "https://pro.tknhub.cc" ]] || fail "域名不是 Pro"
[[ "${PRODUCT}" == "pro" ]] || fail "发布清单不是 Pro"
[[ "${EXPECTED_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "发布清单 commit 非法"
[[ "${MANIFEST_IMAGE}" == "${IMAGE}" ]] || fail "镜像摘要与发布清单不一致"
if [[ "${DATABASE_CHANGE_COUNT}" -gt 0 && "${ALLOW_MIGRATIONS}" != true ]]; then
  fail "本次包含 ${DATABASE_CHANGE_COUNT} 个数据库迁移或 schema 变更；检查兼容性后必须显式传入 --allow-migrations"
fi

echo "[pro-deploy] 目标: ${SSH_USER}@${HOST} (${BASE_URL})"
echo "[pro-deploy] 镜像: ${IMAGE}"
echo "[pro-deploy] 提交: ${EXPECTED_COMMIT}"
echo "[pro-deploy] 数据库变更数: ${DATABASE_CHANGE_COUNT}，自动应用回退: ${AUTO_ROLLBACK}"

if [[ "${EXECUTE}" != true ]]; then
  echo "[pro-deploy] CHECK ONLY：未连接服务器；传入 --execute 后才会部署。"
  exit 0
fi

command -v ssh >/dev/null 2>&1 || fail "缺少 ssh"
command -v scp >/dev/null 2>&1 || fail "缺少 scp"

[[ "$(git -C "${REPO_ROOT}" rev-parse HEAD)" == "${EXPECTED_COMMIT}" ]] || fail "当前 HEAD 与发布清单不一致"
[[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ]] || fail "工作区不干净，禁止部署"

SSH_KEY="${HOME}/.ssh/id_ed25519_sharktech"
[[ -f "${SSH_KEY}" ]] || fail "SSH 私钥不存在: ${SSH_KEY}"
SSH_OPTIONS=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10)
REMOTE="${SSH_USER}@${HOST}"
RELEASE_ID="app-${EXPECTED_COMMIT:0:8}-$(date -u +%Y%m%dT%H%M%SZ)"
REMOTE_RELEASE_DIR="/opt/tokenrouter-pro/releases/${RELEASE_ID}"
OVERRIDE_SHA="$(shasum -a 256 "${OVERRIDE_FILE}" | awk '{print $1}')"
MANIFEST_SHA="$(shasum -a 256 "${RELEASE_MANIFEST}" | awk '{print $1}')"

ssh "${SSH_OPTIONS[@]}" "${REMOTE}" "mkdir -p '${REMOTE_RELEASE_DIR}'"
scp "${SSH_OPTIONS[@]}" "${OVERRIDE_FILE}" "${REMOTE}:${REMOTE_RELEASE_DIR}/compose.image-override.yaml"
scp "${SSH_OPTIONS[@]}" "${RELEASE_MANIFEST}" "${REMOTE}:${REMOTE_RELEASE_DIR}/release-manifest.json"
ssh "${SSH_OPTIONS[@]}" "${REMOTE}" \
  "echo '${OVERRIDE_SHA}  ${REMOTE_RELEASE_DIR}/compose.image-override.yaml' | sha256sum -c - && echo '${MANIFEST_SHA}  ${REMOTE_RELEASE_DIR}/release-manifest.json' | sha256sum -c -"

ssh "${SSH_OPTIONS[@]}" "${REMOTE}" bash -s -- \
  "${IMAGE}" "${EXPECTED_COMMIT}" "${COMPOSE_FILE}" "${REMOTE_OVERRIDE}" \
  "${APP_CONTAINER}" "${DB_CONTAINER}" "${BASE_URL}" "${HEALTH_PATH}" \
  "${REMOTE_RELEASE_DIR}" "${DATABASE_CHANGE_COUNT}" "${AUTO_ROLLBACK}" "${MARKER_REGEX}" <<'REMOTE_SCRIPT'
set -euo pipefail

image="$1"
expected_commit="$2"
compose_file="$3"
override_file="$4"
app_container="$5"
db_container="$6"
base_url="$7"
health_path="$8"
release_dir="$9"
database_change_count="${10}"
auto_rollback="${11}"
marker_regex="${12}"
source_url="https://github.com/aether-shell/RootFlowTokenRouter"
switched=false
previous_image=""

rollback_app() {
  status=$?
  trap - ERR
  if [[ "${switched}" == true && "${auto_rollback}" == true && -n "${previous_image}" ]]; then
    echo "[pro-deploy] 验证失败，恢复旧应用镜像 ${previous_image}" >&2
    PRO_APP_IMAGE="${previous_image}" docker compose \
      -f "${compose_file}" -f "${override_file}" up -d --no-deps app || true
  elif [[ "${switched}" == true ]]; then
    echo "[pro-deploy] 发布失败且包含迁移，未自动回退；按发布目录中的数据库备份执行恢复。" >&2
  fi
  exit "${status}"
}
trap rollback_app ERR

[[ -f "${compose_file}" ]]
[[ "$(docker inspect -f '{{.Name}}' "${app_container}")" == "/${app_container}" ]]
[[ "$(docker inspect -f '{{.Name}}' "${db_container}")" == "/${db_container}" ]]

docker pull "${image}"
[[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "org.opencontainers.image.source" }}')" == "${source_url}" ]]
[[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}')" == "${expected_commit}" ]]
[[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "cc.tknhub.product" }}')" == "pro" ]]

install -m 0644 "${release_dir}/compose.image-override.yaml" "${override_file}"
cp "${compose_file}" "${release_dir}/compose.yaml.before"
docker inspect "${app_container}" > "${release_dir}/app.inspect.before.json"
printf '%s\n' "${database_change_count}" > "${release_dir}/database-change-count.txt"
previous_image="$(docker inspect -f '{{.Config.Image}}' "${app_container}")"
printf '%s\n' "${previous_image}" > "${release_dir}/previous-image.txt"

backup_file="${release_dir}/database.before.dump"
docker exec "${db_container}" sh -ceu \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "${backup_file}"
test -s "${backup_file}"
docker exec -i "${db_container}" pg_restore --list < "${backup_file}" >/dev/null

PRO_APP_IMAGE="${image}" docker compose \
  -f "${compose_file}" -f "${override_file}" up -d --no-deps app
switched=true
started_at="$(docker inspect -f '{{.State.StartedAt}}' "${app_container}")"

healthy=false
for _ in $(seq 1 60); do
  state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${app_container}")"
  if [[ "${state}" == "healthy" ]]; then
    healthy=true
    break
  fi
  sleep 2
done
[[ "${healthy}" == true ]]
[[ "$(docker inspect -f '{{.RestartCount}}' "${app_container}")" == "0" ]]
expected_image_id="$(docker image inspect "${image}" --format '{{.Id}}')"
[[ "$(docker inspect -f '{{.Image}}' "${app_container}")" == "${expected_image_id}" ]]

version_output="$(docker exec "${app_container}" /app/sub2api -version 2>&1)"
[[ "${version_output}" == *"${expected_commit}"* ]]
if [[ -n "${marker_regex}" ]]; then
  expected_markers="$(printf '%s\n' "${marker_regex}" | tr '|' '\n' | sort -u)"
  found_markers="$(docker exec "${app_container}" sh -c \
    'grep -aoE "$1" /app/sub2api | sort -u' sh "${marker_regex}")"
  [[ "${found_markers}" == "${expected_markers}" ]]
fi
docker logs --since "${started_at}" "${app_container}" 2>&1 | \
  grep -Ei 'ERROR|FATAL|panic' > "${release_dir}/severe-logs.after.txt" || true
if grep -Ei 'FATAL|panic' "${release_dir}/severe-logs.after.txt" >/dev/null; then
  echo "[pro-deploy] 启动日志包含 FATAL 或 panic" >&2
  exit 1
fi

curl -fsS "${base_url}${health_path}" > "${release_dir}/health.after.json"
curl -fsS -o /dev/null "${base_url}/admin/dashboard"
curl -fsS -o /dev/null "${base_url}/custom/tokenrouter-profitability"
db_user="$(docker exec "${db_container}" printenv POSTGRES_USER)"
db_name="$(docker exec "${db_container}" printenv POSTGRES_DB)"
menu_items="$(docker exec "${db_container}" psql -U "${db_user}" -d "${db_name}" -Atc \
  "SELECT value FROM settings WHERE key = 'custom_menu_items'")"
[[ "${menu_items}" == *"/custom/tokenrouter-profitability"* ]]
docker inspect "${app_container}" > "${release_dir}/app.inspect.after.json"
printf '%s\n' "${version_output}" > "${release_dir}/version.after.txt"
for evidence_file in "${release_dir}"/*; do
  [[ "$(basename "${evidence_file}")" == "SHA256SUMS" ]] && continue
  sha256sum "${evidence_file}"
done > "${release_dir}/SHA256SUMS"
trap - ERR
echo "[pro-deploy] PASS: ${image}"
REMOTE_SCRIPT
