#!/usr/bin/env bash
# 静态验证 Pro 一键升级编排不会跨过二次确认或调用官方更新源。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/tools/pro-upgrade.sh"

bash -n "${SCRIPT}"
"${SCRIPT}" --help >/dev/null

grep -Fq 'pro-upgrade:' "${REPO_ROOT}/Makefile"
grep -Fq 'pro-upgrade-release:' "${REPO_ROOT}/Makefile"
grep -Fq 'PRO_EXECUTE=1 is required' "${REPO_ROOT}/Makefile"
grep -Fq 'remote_current_commit' "${SCRIPT}"
grep -Fq 'pro-image-dispatch' "${SCRIPT}"
grep -Fq 'snapshot_run_ids' "${SCRIPT}"
grep -Fq 'find_new_dispatched_run' "${SCRIPT}"
grep -Fq 'gh_cli run watch' "${SCRIPT}"
grep -Fq 'gh_cli run download' "${SCRIPT}"
grep -Fq 'tools/pro-remote-check.sh' "${SCRIPT}"
grep -Fq 'release 必须显式传入 --execute' "${SCRIPT}"
grep -Fq 'aether-shell/RootFlowTokenRouter' "${SCRIPT}"
grep -Fq 'env -u GITHUB_TOKEN -u GH_TOKEN gh' "${SCRIPT}"
grep -Fq 'ready state 字段类型或格式非法' "${SCRIPT}"
grep -Fq 'ready state 数据库变更数与发布清单不一致' "${SCRIPT}"
grep -Fq '"${run_id}" =~ ^[1-9][0-9]*$' "${SCRIPT}"
grep -Fq 'SELF_UPDATE_DISABLED' "${REPO_ROOT}/backend/internal/service/update_service.go"
grep -Fq 'BUILD_TYPE=pro' "${REPO_ROOT}/tools/pro-image.sh"
grep -Fq 'BUILD_TYPE=pro' "${REPO_ROOT}/.github/workflows/pro-verify.yml"

prepare_body="$(sed -n '/^prepare_upgrade()/,/^release_upgrade()/p' "${SCRIPT}")"
if [[ "${prepare_body}" == *'--execute'* ]]; then
  echo "Pro 一键准备阶段不得执行发布" >&2
  exit 1
fi
if [[ "${prepare_body}" == *'tools/pro-deploy.sh'* ]]; then
  echo "Pro 一键准备阶段不得调用部署脚本" >&2
  exit 1
fi
if grep -Fq 'TokenFlux/TokenRouter' "${SCRIPT}"; then
  echo "Pro 一键升级不得调用上游官方 Release" >&2
  exit 1
fi

echo "pro upgrade contract tests: PASS"
