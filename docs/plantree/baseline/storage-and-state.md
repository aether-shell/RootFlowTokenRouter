# Storage And State

PostgreSQL 是发布回退的关键持久状态。应用启动会执行 SQL 迁移和 schema 对齐，因此镜像回退不等于数据库回退；有 SQL 迁移或 Ent schema 变化的发布必须保留并验证升级前 dump，且禁止自动应用回退。
