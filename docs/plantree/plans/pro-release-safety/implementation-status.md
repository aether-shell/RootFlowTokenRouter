# Implementation Status

Date: 2026-09-04

## Current Phase

上游 v0.1.276 已合并并发布；本次发布暴露的问题已沉淀为自动镜像调度、发布前远端镜像预检和分阶段错误门禁。

## Next Operational Check

- 线上应用 commit 为 `aa2d857c3993d0e050106bf4fd8537705ee1aba0`；其后的提交只包含发布工具和文档，不代表线上应用版本。
- 下一次应用发布必须以 `aa2d857c3993d0e050106bf4fd8537705ee1aba0` 作为 `PRO_BASE_REF` 重新生成清单。
- 正式切换前先为服务器配置最小 `read:packages` GHCR 凭据，并单独执行 `make pro-remote-check`。

## Done This Phase

- 已设计唯一 Pro 仓库、完整镜像、摘要部署和迁移分级回退契约。
- 已实现二开清单、门禁、镜像构建、部署脚本、CI、测试和运维文档。
- 严格门禁已验证会拒绝脏工作区；开发模式门禁全部通过。
- 已同步上游 v0.1.276，并按 fork 现有编号接入迁移 259–264。
- 已发布 `0.1.276-pro.aa2d857c`，仅重建 app；PostgreSQL、Redis、盈利 sidecar和透明度 sidecar 容器 ID 未变化。
- 已修复清单 clean 标志、SSH marker 参数和盈利 sidecar 验收路径三项发布工具问题。
- 已增加 `make pro-image-dispatch`，自动读取完整 HEAD，并避免失效 shell `GITHUB_TOKEN` 覆盖 GitHub CLI 凭据。
- 已增加只拉取和核验镜像的 `make pro-remote-check`；正式发布在创建目录、备份和切换前强制复用该预检。
- 已将发布错误细分到镜像预检、文件上传、备份、应用切换、运行时验证、HTTP 验收和证据归档阶段。
- 已归档 [v0.1.276 发布复盘](history/2026-09-04-v0.1.276-release.md)。

## Blockers

无。

## Last Landed

Pro v0.1.276 发布流程加固（2026-09-04，当前提交）。发布结果证据见 [复盘记录](history/2026-09-04-v0.1.276-release.md)。

## Last Verified Commands

- `GOTOOLCHAIN=auto python3 tools/pro_release_guard.py --development`
- `GOTOOLCHAIN=auto go test ./...`
- `NODE_OPTIONS=--no-experimental-webstorage pnpm run test:run`（314 文件，2217 项）
- `pnpm run lint:check`
- `pnpm run build`
- `bash deploy/tests/pro-release-contract-test.sh`
- `docker buildx build --check --file Dockerfile .`
- `git diff --check`
- `make pro-verify`
- GitHub Actions `Pro Image` run `33874725031`
- 线上镜像标签、版本、四个二开 marker、迁移 259–264、数据库 dump、页面状态和 sidecar 容器 ID 验收
