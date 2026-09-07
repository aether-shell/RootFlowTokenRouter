# Risk Hotspots

- 上游大版本合并覆盖 fork 行为。
- 多个本地 checkout 导致从错误目录构建。
- 可变镜像标签或手工替换二进制破坏可追溯性。
- 前向迁移导致应用无法独立回退。
- Compose 操作误重建数据库、Redis 或 sidecar。
- 失效的 shell `GITHUB_TOKEN` 覆盖 GitHub CLI keyring 凭据、多 remote 让 `gh` 选中上游仓库，或手工填写错误 commit 触发错误/失败构建。
- 服务器缺少 GHCR `read:packages` 凭据，且镜像拉取检查过晚，留下不完整发布目录或无效备份。
- SSH 参数含 shell 元字符、运行时页面路径漂移或错误阶段不透明，造成部署脚本误报并诱发错误回退判断。
- 在 Pro 上使用源项目自更新或官方二进制回退，会直接覆盖 fork 二开；Pro 镜像必须使用受管构建类型并拒绝这些入口。
- 准备升级后 HEAD、发布清单、数据库变更数或线上 app 基线发生漂移，却继续消费旧 ready state，可能发布错误镜像或绕过迁移确认。
