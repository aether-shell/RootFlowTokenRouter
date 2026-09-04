# TokenRouter Agent 协作规范

## Pro 与 TR 系统边界

- 当前仓库及其 fork 对应 `pro.tknhub.cc`（简称 Pro）。`tr.tknhub.cc`（简称 TR）是另一套完全独立的系统。
- Pro 与 TR 不是同一套系统的测试、灰度、生产、备份或回退环境；不得把其中一套的版本、配置、数据、镜像、部署状态或操作结论套用到另一套。
- 处理 Pro 任务时，默认范围只包括 Pro。未经用户针对 TR 的单独明确授权，不得读取、比较、修改、部署、重启或以其他方式操作 TR，也不得把 TR 纳入 Pro 的升级或验证流程。
- Pro 同步源项目时，必须在 Pro fork 中吸收上游更新并完整保留、适配和验证 Pro 二开功能；不得用官方镜像直接替换 Pro fork。
- 执行任何远端写操作前，必须明确核对目标域名、主机、仓库、分支、镜像、容器和数据库均属于本次获授权的系统。目标归属不明确时停止操作并向用户确认。

## 通用规范

- 代码必须包含注释，注释统一使用中文。
- Commit message 必须遵循 Conventional Commits 规范。
- 不得提交 `SYNC.md`。
- 除非用户明确要求，否则不得创建或切换 Git 分支；所有任务直接在当前 `main` 分支上完成。

## 计划模式

- 使用 Codex 计划模式时，开始实施前必须先将计划原样保存到 `.agents/plans/`，不允许对撰写好的计划进行修改或简化，确保执行期间可以随时回看；执行期间将任务进度同步到计划文件末尾中。这些计划不需要提交到git仓库

## 前端规范

- 需要选择框时，必须使用项目自研的选择框组件，不得使用原生 `<select>`。

## 上游同步

- 如果上游在 `backend/migrations/` 下新增迁移，不得原样照搬文件名；必须根据当前 fork 的最新迁移 ID 递增后，替换文件名前缀 ID。
- 如果上游在 `README.md` 中新增文档，必须将内容并入 `docs/` 下合适的文档；没有合适文档时新建一篇，不要直接写入 `README.md`，保持其简洁。

## Pro 发布门禁

- Pro 应用的唯一规范仓库是当前仓库，`origin` 必须为 `aether-shell/RootFlowTokenRouter`，发布分支必须为干净且与 `origin/main` 一致的 `main`。
- 每次上游同步或 Pro 发布前必须执行 `make pro-verify`。正式发布清单必须通过 `make pro-release-manifest PRO_BASE_REF=<当前线上提交>` 生成，不得手写或复用旧清单。
- Pro 镜像必须从清单锁定的完整源码树构建，并包含 fork source、完整 revision 与 `cc.tknhub.product=pro` 标签。禁止以官方镜像、`latest`、可变标签或手工替换二进制作为正式发布产物。
- Pro 应用发布的唯一入口是 `make pro-release`，且必须使用 GHCR `sha256` 摘要和显式 `PRO_EXECUTE=1`。不得绕过脚本直接修改 Compose 或重建容器。
- 发布门禁以 `deploy/pro/customizations.yaml` 为二开清单。新增、删除或改变 Pro 二开功能时，必须同步更新其代码路径、测试或运行时检查。
- 只允许发布脚本使用 `--no-deps` 更新 Pro 的 `app` 服务。PostgreSQL、Redis、盈利 sidecar、透明度 sidecar和 TR 均不属于应用镜像更新范围。
- `GET /health` 只证明进程存活。发布成功还必须核对镜像标签、内嵌 commit、重启次数、二开标识、管理页面和盈利页面。
