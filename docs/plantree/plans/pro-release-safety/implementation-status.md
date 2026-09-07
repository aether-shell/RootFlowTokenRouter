# Implementation Status

Date: 2026-09-06

## Current Phase

上游 v0.1.278、Pro 二开适配和两段式升级改动已提交并推送到 `origin/main`；当前尚未运行升级准备或发布。

## Active TODO

- 推送后运行 `make pro-upgrade`，验证真实 workflow 和远端只读预检。
- READY 后停止；迁移 265 会删除数据共享表和字段，只有取得用户二次确认并显式设置 `PRO_ALLOW_MIGRATIONS=1` 才能切换生产。

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
- 已实现两段式 `make pro-upgrade` / `make pro-upgrade-release`，ready state 绑定 fork HEAD、线上基线、镜像、清单和数据库变更数。
- 已为 Pro 镜像注入 `BuildType=pro`，后端拒绝官方自更新/回退，前端隐藏原生回退入口。
- 已通过升级/发布契约、受管更新焦点测试、前端测试和类型检查、YAML/shell 静态检查及 Dockerfile 构建定义检查。
- 已将上游 v0.1.278 以 merge commit `c3b80cd3` 合入本地 `main`，保留 Pro 客户端策略、仪表盘分组筛选、PostgreSQL 工具、盈利 sidecar 和发布门禁。
- 已吸收 v0.1.277–v0.1.278 的 TF CLI 导入、GPT-6 Astra、分组页签/菜单、API Key 近 30 天用量、模型目录和别名定价修复，并下线数据共享功能。
- 已将 Pro 上游基线更新为 `e7906995`，并把上游标签中滞后的 VERSION 修正为 `0.1.278`。
- 迁移 265 已通过隔离 PostgreSQL/Redis 集成测试；后端全仓编译、Pro 开发门禁、前端 319 文件 2279 项测试、lint 和生产构建均通过。

## Blockers

无。

## Last Landed

Pro 升级门禁（2026-09-06，`93fd6932`）已推送到 `origin/main`；其父提交包含上游 v0.1.278 merge（`c3b80cd3`）。

## Last Verified Commands

- `GOTOOLCHAIN=auto python3 tools/pro_release_guard.py --development`
- `bash deploy/tests/pro-release-contract-test.sh`
- `bash deploy/tests/pro-upgrade-contract-test.sh`
- `GOCACHE=/private/tmp/tokenrouter-go-cache GOTOOLCHAIN=auto go test -tags=unit ./internal/service -run '^TestUpdateServiceProBuildDisablesOfficialSelfUpdate$'`
- `GOTOOLCHAIN=auto go test ./... -run '^$'`
- `GOTOOLCHAIN=auto go test -tags=integration ./internal/repository -run '^TestMigration265RemovesDataSharing$'`
- `GOTOOLCHAIN=auto go test ./internal/service -run 'Test(ModelPricingResolverCatalogAlias|PricingCatalogLookup|OpenAIRemovedGPT56Alias|OpenAIModelAlias|PricingService)'`
- `GOTOOLCHAIN=auto go test ./internal/handler ./internal/server/routes -run 'Test(OpenAIReasoningEffortPolicy|RemovedFeatureRoutes)'`
- `NODE_OPTIONS=--no-experimental-webstorage pnpm run test:run`（319 文件，2279 项）
- `pnpm run lint:check`
- `pnpm run build`
- `docker buildx build --check --file Dockerfile .`
- `git diff --check`
