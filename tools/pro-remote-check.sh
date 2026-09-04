#!/usr/bin/env bash
# 在任何发布写操作前，验证 Pro 主机可拉取并识别指定的不可变 fork 镜像。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CUSTOMIZATIONS="${REPO_ROOT}/deploy/pro/customizations.yaml"
RELEASE_MANIFEST="${REPO_ROOT}/build/pro-release-manifest.json"
IMAGE=""
STAGE="local_validation"

usage() {
  cat <<'EOF'
用法：tools/pro-remote-check.sh --image <ghcr.io/...@sha256:...> [选项]

选项：
  --manifest <path>       指定 release-manifest.json
  --help                  显示帮助
EOF
}

fail() {
  echo "[pro-remote-check] FAIL stage=${STAGE}: $*" >&2
  exit 1
}

report_error() {
  status=$?
  trap - ERR
  echo "[pro-remote-check] FAIL stage=${STAGE} status=${status}" >&2
  exit "${status}"
}
trap report_error ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:-}"; shift 2 ;;
    --manifest) RELEASE_MANIFEST="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "缺少 jq"
command -v ssh >/dev/null 2>&1 || fail "缺少 ssh"
[[ -f "${CUSTOMIZATIONS}" ]] || fail "缺少 Pro 二开清单"
[[ -f "${RELEASE_MANIFEST}" ]] || fail "发布清单不存在: ${RELEASE_MANIFEST}"
[[ "${IMAGE}" =~ ^ghcr\.io/aether-shell/rootflowtokenrouter@sha256:[0-9a-f]{64}$ ]] || \
  fail "镜像必须使用 Pro GHCR 的不可变 sha256 摘要"

HOST="$(jq -r '.runtime_contract.ssh_host' "${CUSTOMIZATIONS}")"
SSH_USER="$(jq -r '.runtime_contract.ssh_user' "${CUSTOMIZATIONS}")"
SSH_IDENTITY="$(jq -r '.runtime_contract.ssh_identity_file' "${CUSTOMIZATIONS}")"
COMPOSE_FILE="$(jq -r '.runtime_contract.compose_file' "${CUSTOMIZATIONS}")"
COMPOSE_PROJECT="$(jq -r '.runtime_contract.compose_project' "${CUSTOMIZATIONS}")"
APP_CONTAINER="$(jq -r '.runtime_contract.app_container' "${CUSTOMIZATIONS}")"
APP_SERVICE="$(jq -r '.runtime_contract.app_service' "${CUSTOMIZATIONS}")"
DB_CONTAINER="$(jq -r '.runtime_contract.database_container' "${CUSTOMIZATIONS}")"
DB_SERVICE="$(jq -r '.runtime_contract.database_service' "${CUSTOMIZATIONS}")"
EXPECTED_COMMIT="$(jq -r '.source.commit // empty' "${RELEASE_MANIFEST}")"
PRODUCT="$(jq -r '.product // empty' "${RELEASE_MANIFEST}")"
MANIFEST_IMAGE="$(jq -r '.image.reference // empty' "${RELEASE_MANIFEST}")"

[[ "${HOST}" == "67.21.68.75" ]] || fail "目标不是固定 Pro 主机"
[[ "${SSH_USER}" == "root" ]] || fail "SSH 用户不是 Pro 约定用户"
[[ "${SSH_IDENTITY}" == "~/.ssh/id_ed25519_sharktech" ]] || fail "SSH 私钥路径不是 Pro 约定路径"
[[ "${COMPOSE_FILE}" == "/opt/tokenrouter-pro/compose.yaml" ]] || fail "Compose 路径不是 Pro"
[[ "${COMPOSE_PROJECT}" == "tokenrouter-pro" ]] || fail "Compose 项目不是 Pro"
[[ "${APP_CONTAINER}" == "tokenrouter-pro-app" && "${APP_SERVICE}" == "app" ]] || fail "应用容器归属不是 Pro"
[[ "${DB_CONTAINER}" == "tokenrouter-pro-postgres" && "${DB_SERVICE}" == "postgres" ]] || fail "数据库容器归属不是 Pro"
[[ "${PRODUCT}" == "pro" ]] || fail "发布清单不是 Pro"
[[ "${EXPECTED_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "发布清单 commit 非法"
[[ "${MANIFEST_IMAGE}" == "${IMAGE}" ]] || fail "镜像摘要与发布清单不一致"
[[ "$(git -C "${REPO_ROOT}" rev-parse HEAD)" == "${EXPECTED_COMMIT}" ]] || fail "当前 HEAD 与发布清单不一致"
[[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ]] || fail "工作区不干净，禁止远端预检"

SSH_KEY="${HOME}/.ssh/id_ed25519_sharktech"
[[ -f "${SSH_KEY}" ]] || fail "SSH 私钥不存在: ${SSH_KEY}"
SSH_OPTIONS=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10)
REMOTE="${SSH_USER}@${HOST}"
STAGE="image_preflight"

ssh "${SSH_OPTIONS[@]}" "${REMOTE}" bash -s -- \
  "${IMAGE}" "${EXPECTED_COMMIT}" "${COMPOSE_FILE}" "${COMPOSE_PROJECT}" \
  "${APP_CONTAINER}" "${APP_SERVICE}" "${DB_CONTAINER}" "${DB_SERVICE}" <<'REMOTE_SCRIPT'
set -euo pipefail

image="$1"
expected_commit="$2"
compose_file="$3"
compose_project="$4"
app_container="$5"
app_service="$6"
db_container="$7"
db_service="$8"
source_url="https://github.com/aether-shell/RootFlowTokenRouter"
stage="image_preflight"

report_error() {
  status=$?
  trap - ERR
  echo "[pro-remote-check] FAIL stage=${stage} status=${status}" >&2
  exit "${status}"
}
trap report_error ERR

verify_container_owner() {
  container="$1"
  service="$2"
  [[ "$(docker inspect -f '{{.Name}}' "${container}")" == "/${container}" ]]
  [[ "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "${container}")" == "${compose_project}" ]]
  [[ "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "${container}")" == "${service}" ]]
  config_files="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "${container}")"
  case ",${config_files}," in
    *",${compose_file},"*) ;;
    *) return 1 ;;
  esac
}

[[ -f "${compose_file}" ]]
verify_container_owner "${app_container}" "${app_service}"
verify_container_owner "${db_container}" "${db_service}"
docker pull "${image}"
[[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "org.opencontainers.image.source" }}')" == "${source_url}" ]]
[[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}')" == "${expected_commit}" ]]
[[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "cc.tknhub.product" }}')" == "pro" ]]
trap - ERR
REMOTE_SCRIPT

trap - ERR
echo "[pro-remote-check] PASS: ${IMAGE}"
