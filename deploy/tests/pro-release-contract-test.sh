#!/usr/bin/env bash
# 本地验证 Pro 发布工具的静态契约，不连接服务器或构建镜像。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFEST="${REPO_ROOT}/deploy/pro/customizations.yaml"

bash -n "${REPO_ROOT}/tools/pro-image.sh"
bash -n "${REPO_ROOT}/tools/pro-remote-check.sh"
bash -n "${REPO_ROOT}/tools/pro-deploy.sh"
python3 -m py_compile "${REPO_ROOT}/tools/pro_release_guard.py"
PYTHONDONTWRITEBYTECODE=1 python3 "${REPO_ROOT}/deploy/tests/pro_release_guard_test.py"
jq -e '.schema_version == 1 and .product == "pro"' "${MANIFEST}" >/dev/null

IMAGE_CHECK_OUTPUT="$("${REPO_ROOT}/tools/pro-image.sh" \
  "${REPO_ROOT}/deploy/tests/fixtures/pro-release-manifest.json" 2>&1 || true)"
if [[ "${IMAGE_CHECK_OUTPUT}" != *"当前 HEAD 与发布清单不一致"* ]]; then
  echo "Pro 镜像脚本错误拒绝了 source.dirty=false 的干净清单" >&2
  exit 1
fi

grep -Fq '67.21.68.75' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq 'tokenrouter-pro-app' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq -- '--no-deps app' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq 'stage="backup"' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq 'STAGE="remote_release"' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq 'stage="switch_app"' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq 'stage="runtime_verify"' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq 'stage="http_verify"' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq 'stage="evidence_finalize"' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq 'MARKER_REGEX_B64=' "${REPO_ROOT}/tools/pro-deploy.sh"
grep -Fq '"${MARKER_REGEX_B64}" "${PROFITABILITY_PATH_B64}" <<' "${REPO_ROOT}/tools/pro-deploy.sh"
jq -e '.customizations[] | select(.id == "profitability-sidecar") | .runtime_http_paths == ["/profitability/?view=profitability"]' \
  "${MANIFEST}" >/dev/null
grep -Fq 'PROFITABILITY_PATH_B64=' "${REPO_ROOT}/tools/pro-deploy.sh"
if grep -Fq '/custom/tokenrouter-profitability' "${REPO_ROOT}/tools/pro-deploy.sh"; then
  echo "Pro 部署脚本仍包含过期盈利页面路径" >&2
  exit 1
fi
if grep -Fq 'tr.tknhub.cc' "${REPO_ROOT}/tools/pro-deploy.sh"; then
  echo "Pro 部署脚本不得包含 TR 域名" >&2
  exit 1
fi

grep -Fq 'pro-image-dispatch:' "${REPO_ROOT}/Makefile"
grep -Fq 'commit="$$(git rev-parse HEAD)"' "${REPO_ROOT}/Makefile"
grep -Fq 'env -u GITHUB_TOKEN gh workflow run pro-image.yml --repo aether-shell/RootFlowTokenRouter' "${REPO_ROOT}/Makefile"
grep -Fq 'pro-remote-check:' "${REPO_ROOT}/Makefile"
grep -Fq 'tools/pro-remote-check.sh' "${REPO_ROOT}/Makefile"

grep -Fq 'stage="image_preflight"' "${REPO_ROOT}/tools/pro-remote-check.sh"
grep -Fq 'docker pull "${image}"' "${REPO_ROOT}/tools/pro-remote-check.sh"
grep -Fq 'com.docker.compose.project' "${REPO_ROOT}/tools/pro-remote-check.sh"
grep -Fq 'cc.tknhub.product' "${REPO_ROOT}/tools/pro-remote-check.sh"
for forbidden in 'pg_dump' 'pg_restore' 'docker compose' 'mkdir -p' 'scp '; do
  if grep -Fq "${forbidden}" "${REPO_ROOT}/tools/pro-remote-check.sh"; then
    echo "Pro 远端预检包含发布写操作: ${forbidden}" >&2
    exit 1
  fi
done
if grep -Fq 'tr.tknhub.cc' "${REPO_ROOT}/tools/pro-remote-check.sh"; then
  echo "Pro 远端预检不得包含 TR 域名" >&2
  exit 1
fi

preflight_line="$(grep -n 'bash "${REMOTE_CHECK_SCRIPT}"' "${REPO_ROOT}/tools/pro-deploy.sh" | head -1 | cut -d: -f1)"
release_dir_line="$(grep -n 'mkdir -p.*REMOTE_RELEASE_DIR' "${REPO_ROOT}/tools/pro-deploy.sh" | head -1 | cut -d: -f1)"
if [[ -z "${preflight_line}" || -z "${release_dir_line}" || "${preflight_line}" -ge "${release_dir_line}" ]]; then
  echo "Pro 正式发布没有在创建发布目录前复用远端镜像预检" >&2
  exit 1
fi
jq -e '.runtime_contract | .compose_project == "tokenrouter-pro" and .app_service == "app" and .database_service == "postgres"' \
  "${MANIFEST}" >/dev/null

"${REPO_ROOT}/tools/pro-deploy.sh" --help >/dev/null
if "${REPO_ROOT}/tools/pro-deploy.sh" \
  --manifest "${REPO_ROOT}/deploy/tests/fixtures/pro-release-manifest.json" \
  --image 'ghcr.io/tokenflux/tokenrouter:latest' >/dev/null 2>&1; then
  echo "Pro 部署脚本接受了可漂移或非 fork 镜像" >&2
  exit 1
fi

DRY_RUN_OUTPUT="$("${REPO_ROOT}/tools/pro-deploy.sh" \
  --manifest "${REPO_ROOT}/deploy/tests/fixtures/pro-release-manifest.json" \
  --image 'ghcr.io/aether-shell/rootflowtokenrouter@sha256:0000000000000000000000000000000000000000000000000000000000000000')"
[[ "${DRY_RUN_OUTPUT}" == *"CHECK ONLY"* ]]

echo "pro release contract tests: PASS"
