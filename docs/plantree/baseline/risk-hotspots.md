# Risk Hotspots

- 上游大版本合并覆盖 fork 行为。
- 多个本地 checkout 导致从错误目录构建。
- 可变镜像标签或手工替换二进制破坏可追溯性。
- 前向迁移导致应用无法独立回退。
- Compose 操作误重建数据库、Redis 或 sidecar。
