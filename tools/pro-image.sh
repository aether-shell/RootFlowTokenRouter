#!/usr/bin/env bash
# 从发布清单锁定的 fork 提交完整构建 Pro 镜像，不推送、不部署。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_MANIFEST="${1:-${REPO_ROOT}/build/pro-release-manifest.json}"

fail() {
  echo "[pro-image] FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "缺少 jq"
command -v docker >/dev/null 2>&1 || fail "缺少 docker"
[[ -f "${RELEASE_MANIFEST}" ]] || fail "发布清单不存在: ${RELEASE_MANIFEST}"

PRODUCT="$(jq -r '.product // empty' "${RELEASE_MANIFEST}")"
COMMIT="$(jq -r '.source.commit // empty' "${RELEASE_MANIFEST}")"
TREE="$(jq -r '.source.tree // empty' "${RELEASE_MANIFEST}")"
DIRTY="$(jq -r '.source.dirty' "${RELEASE_MANIFEST}")"
[[ "${PRODUCT}" == "pro" ]] || fail "发布清单不是 Pro"
[[ "${COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "发布清单 commit 非法"
[[ "${TREE}" =~ ^[0-9a-f]{40}$ ]] || fail "发布清单 tree 非法"
[[ "${DIRTY}" == "false" ]] || fail "发布清单来自脏工作区"

CURRENT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
CURRENT_TREE="$(git -C "${REPO_ROOT}" rev-parse 'HEAD^{tree}')"
[[ "${CURRENT_COMMIT}" == "${COMMIT}" ]] || fail "当前 HEAD 与发布清单不一致"
[[ "${CURRENT_TREE}" == "${TREE}" ]] || fail "当前源码树与发布清单不一致"
[[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ]] || fail "工作区不干净"

SOURCE_URL="https://github.com/aether-shell/RootFlowTokenRouter"
IMAGE_REPOSITORY="ghcr.io/aether-shell/rootflowtokenrouter"
VERSION_BASE="$(tr -d '\r\n' < "${REPO_ROOT}/backend/cmd/server/VERSION")"
VERSION="${VERSION_BASE}-pro.${COMMIT:0:8}"
IMAGE="${PRO_IMAGE:-${IMAGE_REPOSITORY}:${COMMIT}}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ "${IMAGE}" == "${IMAGE_REPOSITORY}:${COMMIT}" ]] || fail "镜像 tag 必须是 Pro GHCR 仓库加完整 commit"

echo "[pro-image] 构建 ${IMAGE}"
docker build \
  --build-arg "VERSION=${VERSION}" \
  --build-arg "COMMIT=${COMMIT}" \
  --build-arg "DATE=${BUILD_DATE}" \
  --label "org.opencontainers.image.source=${SOURCE_URL}" \
  --label "org.opencontainers.image.revision=${COMMIT}" \
  --label "org.opencontainers.image.version=${VERSION}" \
  --label "cc.tknhub.product=pro" \
  --tag "${IMAGE}" \
  --file "${REPO_ROOT}/Dockerfile" \
  "${REPO_ROOT}"

inspect_label() {
  docker image inspect "${IMAGE}" --format "{{ index .Config.Labels \"$1\" }}"
}

[[ "$(inspect_label org.opencontainers.image.source)" == "${SOURCE_URL}" ]] || fail "镜像 source 标签错误"
[[ "$(inspect_label org.opencontainers.image.revision)" == "${COMMIT}" ]] || fail "镜像 revision 标签错误"
[[ "$(inspect_label cc.tknhub.product)" == "pro" ]] || fail "镜像 product 标签错误"

VERSION_OUTPUT="$(docker run --rm --entrypoint /app/sub2api "${IMAGE}" -version 2>&1)"
[[ "${VERSION_OUTPUT}" == *"${COMMIT}"* ]] || fail "二进制未嵌入预期 commit"

while IFS= read -r command_json; do
  image_command=()
  while IFS= read -r argument; do
    image_command+=("${argument}")
  done < <(jq -r '.[]' <<<"${command_json}")
  docker run --rm --entrypoint "${image_command[0]}" "${IMAGE}" "${image_command[@]:1}" >/dev/null
done < <(jq -c '.customizations[] | .image_commands[]?' "${REPO_ROOT}/deploy/pro/customizations.yaml")

MARKER_REGEX="$(jq -r '[.customizations[] | .binary_markers[]?] | join("|")' "${REPO_ROOT}/deploy/pro/customizations.yaml")"
if [[ -n "${MARKER_REGEX}" ]]; then
  EXPECTED_MARKERS="$(printf '%s\n' "${MARKER_REGEX}" | tr '|' '\n' | sort -u)"
  FOUND_MARKERS="$(docker run --rm --entrypoint sh "${IMAGE}" -c \
    'grep -aoE "$1" /app/sub2api | sort -u' sh "${MARKER_REGEX}")"
  [[ "${FOUND_MARKERS}" == "${EXPECTED_MARKERS}" ]] || fail "镜像缺少二开二进制标识"
fi

IMAGE_ID="$(docker image inspect "${IMAGE}" --format '{{.Id}}')"
TMP_MANIFEST="${RELEASE_MANIFEST}.tmp"
jq \
  --arg tag "${IMAGE}" \
  --arg id "${IMAGE_ID}" \
  --arg built_at "${BUILD_DATE}" \
  --arg version "${VERSION}" \
  '.image = {tag: $tag, id: $id, built_at: $built_at, version: $version}' \
  "${RELEASE_MANIFEST}" > "${TMP_MANIFEST}"
mv "${TMP_MANIFEST}" "${RELEASE_MANIFEST}"

echo "[pro-image] PASS: ${IMAGE} (${IMAGE_ID})"
echo "[pro-image] 本脚本不会推送镜像，也不会连接服务器。"
