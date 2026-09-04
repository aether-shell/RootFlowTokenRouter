# Risk Hotspots

- 上游大版本合并覆盖 fork 行为。
- 多个本地 checkout 导致从错误目录构建。
- 可变镜像标签或手工替换二进制破坏可追溯性。
- 前向迁移导致应用无法独立回退。
- Compose 操作误重建数据库、Redis 或 sidecar。
- 失效的 shell `GITHUB_TOKEN` 覆盖 GitHub CLI keyring 凭据，或手工填写错误 commit 触发错误/失败构建。
- 服务器缺少 GHCR `read:packages` 凭据，且镜像拉取检查过晚，留下不完整发布目录或无效备份。
- SSH 参数含 shell 元字符、运行时页面路径漂移或错误阶段不透明，造成部署脚本误报并诱发错误回退判断。
