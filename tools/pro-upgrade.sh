#!/usr/bin/env bash
# 将当前已同步的 Pro fork main 自动准备到生产切换前；发布必须单独二次调用。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CUSTOMIZATIONS="${REPO_ROOT}/deploy/pro/customizations.yaml"
MANIFEST="${REPO_ROOT}/build/pro-release-manifest.json"
STATE="${REPO_ROOT}/build/pro-upgrade-ready.json"
GH_REPO="aether-shell/RootFlowTokenRouter"
GH_WORKFLOW="pro-image.yml"
ACTION="${1:-prepare}"
ALLOW_MIGRATIONS=false
EXECUTE=false
STAGE="arguments"

if [[ $# -gt 0 ]]; then
  shift
fi

usage() {
  cat <<'EOF'
用法：
  tools/pro-upgrade.sh prepare [--manifest <path>] [--state <path>]
  tools/pro-upgrade.sh release [--manifest <path>] [--state <path>] [--allow-migrations] --execute

prepare 会构建或复用当前 fork HEAD 的 Pro 镜像，下载发布清单并完成远端预检，
但绝不切换生产。release 只消费 prepare 生成且仍有效的 ready state。
EOF
}

fail() {
  echo "[pro-upgrade] FAIL stage=${STAGE}: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --state) STATE="${2:-}"; shift 2 ;;
    --allow-migrations) ALLOW_MIGRATIONS=true; shift ;;
    --execute) EXECUTE=true; shift ;;
    --help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

case "${ACTION}" in
  prepare|release) ;;
  help|--help|-h) usage; exit 0 ;;
  *) fail "未知动作: ${ACTION}" ;;
esac

file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_clean_main() {
  [[ "$(git -C "${REPO_ROOT}" branch --show-current)" == "main" ]] || fail "当前分支必须是 main"
  [[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ]] || fail "工作区不干净"
  [[ "$(git -C "${REPO_ROOT}" rev-parse HEAD)" == "$(git -C "${REPO_ROOT}" rev-parse origin/main)" ]] || \
    fail "HEAD 必须与 origin/main 一致"
}

load_runtime_contract() {
  command -v jq >/dev/null 2>&1 || fail "缺少 jq"
  [[ -f "${CUSTOMIZATIONS}" ]] || fail "缺少 Pro 二开清单"
  HOST="$(jq -r '.runtime_contract.ssh_host' "${CUSTOMIZATIONS}")"
  SSH_USER="$(jq -r '.runtime_contract.ssh_user' "${CUSTOMIZATIONS}")"
  APP_CONTAINER="$(jq -r '.runtime_contract.app_container' "${CUSTOMIZATIONS}")"
  [[ "${HOST}" == "67.21.68.75" && "${SSH_USER}" == "root" ]] || fail "目标不是固定 Pro 主机"
  [[ "${APP_CONTAINER}" == "tokenrouter-pro-app" ]] || fail "应用容器不是 Pro"
  SSH_KEY="${HOME}/.ssh/id_ed25519_sharktech"
  [[ -f "${SSH_KEY}" ]] || fail "SSH 私钥不存在: ${SSH_KEY}"
  SSH_OPTIONS=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10)
  REMOTE="${SSH_USER}@${HOST}"
}

remote_current_commit() {
  ssh "${SSH_OPTIONS[@]}" "${REMOTE}" \
    "docker inspect -f '{{ index .Config.Labels \"org.opencontainers.image.revision\" }}' '${APP_CONTAINER}'"
}

gh_cli() {
  env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"
}

find_successful_runs() {
  gh_cli run list --repo "${GH_REPO}" --workflow "${GH_WORKFLOW}" --event workflow_dispatch \
    --status success --limit 20 --json databaseId,headSha \
    | jq -r --arg commit "$1" '.[] | select(.headSha == $commit) | .databaseId'
}

snapshot_run_ids() {
  gh_cli run list --repo "${GH_REPO}" --workflow "${GH_WORKFLOW}" --event workflow_dispatch \
    --limit 50 --json databaseId,headSha \
    | jq -c --arg commit "$1" '[.[] | select(.headSha == $commit) | .databaseId]'
}

find_new_dispatched_run() {
  gh_cli run list --repo "${GH_REPO}" --workflow "${GH_WORKFLOW}" --event workflow_dispatch \
    --limit 50 --json databaseId,headSha \
    | jq -r --arg commit "$1" --argjson previous_ids "$2" \
      '[.[] | select(.headSha == $commit) |
        select(.databaseId as $id | $previous_ids | index($id) | not)][0].databaseId // empty'
}

download_valid_manifest() {
  run_id="$1"
  destination="$2"
  [[ "${run_id}" =~ ^[1-9][0-9]*$ ]] || return 1
  mkdir -p "${destination}"
  if ! gh_cli run download "${run_id}" --repo "${GH_REPO}" \
    --name "pro-release-${SOURCE_COMMIT}" --dir "${destination}" >/dev/null 2>&1; then
    return 1
  fi
  candidate="$(find "${destination}" -type f -name 'pro-release-manifest.json' -print -quit)"
  [[ -n "${candidate}" ]] || return 1
  jq -e --arg commit "${SOURCE_COMMIT}" --arg base "${BASE_COMMIT}" \
    '.schema_version == 1 and .product == "pro" and .source.commit == $commit and .base_ref == $base and
     (.changed_migrations | type == "array") and (.changed_database_paths | type == "array") and
     (.image.reference | type == "string") and
     (.image.digest | type == "string") and
     (.image.digest | test("^sha256:[0-9a-f]{64}$")) and
     .image.reference == ("ghcr.io/aether-shell/rootflowtokenrouter@" + .image.digest)' \
    "${candidate}" >/dev/null || return 1
  printf '%s\n' "${candidate}"
}

cleanup_temp_dir() {
  if [[ -n "${temp_dir:-}" && -d "${temp_dir}" &&
        "$(dirname "${temp_dir}")" == "${temp_root}" &&
        "$(basename "${temp_dir}")" == pro-upgrade.* ]]; then
    rm -rf -- "${temp_dir}"
  fi
}

prepare_upgrade() {
  command -v gh >/dev/null 2>&1 || fail "缺少 gh"
  command -v ssh >/dev/null 2>&1 || fail "缺少 ssh"
  command -v shasum >/dev/null 2>&1 || fail "缺少 shasum"
  require_clean_main
  load_runtime_contract

  STAGE="online_base"
  BASE_COMMIT="$(remote_current_commit)"
  [[ "${BASE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "线上应用没有合法的完整 revision 标签"
  SOURCE_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  git -C "${REPO_ROOT}" merge-base --is-ancestor "${BASE_COMMIT}" "${SOURCE_COMMIT}" || \
    fail "线上 commit 不是当前 fork HEAD 的祖先"

  STAGE="local_verify"
  GOTOOLCHAIN=auto python3 "${REPO_ROOT}/tools/pro_release_guard.py"

  temp_root="${TMPDIR:-/tmp}"
  temp_root="${temp_root%/}"
  temp_dir="$(mktemp -d "${temp_root}/pro-upgrade.XXXXXX")"
  trap cleanup_temp_dir EXIT
  successful_runs="$(find_successful_runs "${SOURCE_COMMIT}")"
  run_id=""
  candidate_manifest=""
  while IFS= read -r candidate_run_id; do
    [[ "${candidate_run_id}" =~ ^[1-9][0-9]*$ ]] || continue
    if candidate_manifest="$(download_valid_manifest \
      "${candidate_run_id}" "${temp_dir}/existing-${candidate_run_id}")"; then
      run_id="${candidate_run_id}"
      break
    fi
  done <<< "${successful_runs}"

  if [[ -z "${candidate_manifest}" ]]; then
    STAGE="image_dispatch"
    previous_run_ids="$(snapshot_run_ids "${SOURCE_COMMIT}")"
    jq -e 'type == "array" and all(.[]; type == "number" and . > 0 and floor == .)' \
      <<< "${previous_run_ids}" >/dev/null || fail "无法记录调度前的 workflow run"
    make -C "${REPO_ROOT}" pro-image-dispatch PRO_BASE_REF="${BASE_COMMIT}"
    run_id=""
    for _ in $(seq 1 30); do
      run_id="$(find_new_dispatched_run "${SOURCE_COMMIT}" "${previous_run_ids}")"
      [[ "${run_id}" =~ ^[1-9][0-9]*$ ]] && break
      sleep 2
    done
    [[ "${run_id}" =~ ^[1-9][0-9]*$ ]] || fail "60 秒内没有找到合法的 Pro Image workflow run"

    STAGE="image_workflow"
    gh_cli run watch "${run_id}" --repo "${GH_REPO}" --exit-status --interval 10
    candidate_manifest="$(download_valid_manifest "${run_id}" "${temp_dir}/fresh" || true)"
    [[ -n "${candidate_manifest}" ]] || fail "工作流产物中的发布清单与当前线上基线不一致"
  fi

  STAGE="manifest_install"
  mkdir -p "$(dirname "${MANIFEST}")" "$(dirname "${STATE}")"
  install -m 0644 "${candidate_manifest}" "${MANIFEST}"
  image="$(jq -r '.image.reference' "${MANIFEST}")"
  database_change_count="$(jq -er '(.changed_database_paths // .changed_migrations) as $paths |
    if ($paths | type) == "array" then ($paths | length) else error("database paths must be an array") end' \
    "${MANIFEST}")"
  [[ "${database_change_count}" =~ ^[0-9]+$ ]] || fail "发布清单数据库变更数非法"

  STAGE="remote_preflight"
  bash "${REPO_ROOT}/tools/pro-remote-check.sh" --manifest "${MANIFEST}" --image "${image}"

  STAGE="ready_state"
  manifest_sha="$(file_sha256 "${MANIFEST}")"
  prepared_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_temp="${STATE}.tmp"
  jq -n \
    --arg prepared_at "${prepared_at}" \
    --arg source_commit "${SOURCE_COMMIT}" \
    --arg base_ref "${BASE_COMMIT}" \
    --arg image "${image}" \
    --arg manifest_sha256 "${manifest_sha}" \
    --argjson workflow_run_id "${run_id}" \
    --argjson database_change_count "${database_change_count}" \
    '{schema_version: 1, product: "pro", prepared_at: $prepared_at, source_commit: $source_commit,
      base_ref: $base_ref, image: $image, manifest_sha256: $manifest_sha256,
      workflow_run_id: $workflow_run_id, database_change_count: $database_change_count}' \
    > "${state_temp}"
  mv "${state_temp}" "${STATE}"

  trap - EXIT
  cleanup_temp_dir
  echo "[pro-upgrade] READY: ${image}"
  echo "[pro-upgrade] 线上基线: ${BASE_COMMIT}"
  echo "[pro-upgrade] 数据库变更数: ${database_change_count}"
  echo "[pro-upgrade] 已停止在生产切换前；二次确认后运行 make pro-upgrade-release PRO_EXECUTE=1$(if [[ "${database_change_count}" -gt 0 ]]; then printf ' PRO_ALLOW_MIGRATIONS=1'; fi)"
}

release_upgrade() {
  [[ "${EXECUTE}" == true ]] || fail "release 必须显式传入 --execute"
  command -v jq >/dev/null 2>&1 || fail "缺少 jq"
  command -v shasum >/dev/null 2>&1 || fail "缺少 shasum"
  require_clean_main
  [[ -f "${STATE}" ]] || fail "ready state 不存在，请先运行 make pro-upgrade"
  [[ -f "${MANIFEST}" ]] || fail "发布清单不存在，请先运行 make pro-upgrade"

  STAGE="ready_state_validation"
  jq -e '
    .schema_version == 1 and .product == "pro" and
    (.prepared_at | type == "string") and
    (.prepared_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.source_commit | type == "string") and
    (.source_commit | test("^[0-9a-f]{40}$")) and
    (.base_ref | type == "string") and
    (.base_ref | test("^[0-9a-f]{40}$")) and
    (.image | type == "string") and
    (.image | test("^ghcr\\.io/aether-shell/rootflowtokenrouter@sha256:[0-9a-f]{64}$")) and
    (.manifest_sha256 | type == "string") and
    (.manifest_sha256 | test("^[0-9a-f]{64}$")) and
    (.workflow_run_id | type == "number" and . > 0 and floor == .) and
    (.database_change_count | type == "number" and . >= 0 and floor == .)
  ' "${STATE}" >/dev/null || fail "ready state 字段类型或格式非法"
  source_commit="$(jq -r '.source_commit // empty' "${STATE}")"
  base_ref="$(jq -r '.base_ref // empty' "${STATE}")"
  image="$(jq -r '.image // empty' "${STATE}")"
  expected_manifest_sha="$(jq -r '.manifest_sha256 // empty' "${STATE}")"
  database_change_count="$(jq -r '.database_change_count // -1' "${STATE}")"
  [[ "${source_commit}" == "$(git -C "${REPO_ROOT}" rev-parse HEAD)" ]] || fail "ready state 与当前 HEAD 不一致"
  [[ "$(file_sha256 "${MANIFEST}")" == "${expected_manifest_sha}" ]] || fail "发布清单在预检后发生变化"
  jq -e --arg commit "${source_commit}" --arg base "${base_ref}" --arg image "${image}" \
    '.source.commit == $commit and .base_ref == $base and .image.reference == $image' "${MANIFEST}" >/dev/null || \
    fail "ready state 与发布清单不一致"
  manifest_database_change_count="$(jq -er '(.changed_database_paths // .changed_migrations) as $paths |
    if ($paths | type) == "array" then ($paths | length) else error("database paths must be an array") end' \
    "${MANIFEST}")"
  [[ "${database_change_count}" == "${manifest_database_change_count}" ]] || \
    fail "ready state 数据库变更数与发布清单不一致"
  if [[ "${database_change_count}" -gt 0 && "${ALLOW_MIGRATIONS}" != true ]]; then
    fail "本次包含 ${database_change_count} 个数据库变更，必须显式传入 --allow-migrations"
  fi

  STAGE="release"
  args=(--manifest "${MANIFEST}" --image "${image}" --execute)
  if [[ "${ALLOW_MIGRATIONS}" == true ]]; then
    args+=(--allow-migrations)
  fi
  bash "${REPO_ROOT}/tools/pro-deploy.sh" "${args[@]}"
}

if [[ "${ACTION}" == "prepare" ]]; then
  prepare_upgrade
else
  release_upgrade
fi
