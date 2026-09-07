# Plan Tree

本目录登记需要跨会话维护的工程计划。产品与运行事实以 `docs/index.md` 及其分类文档为准；计划状态以本目录为准；代码和自动化测试是落地证据。

## Baseline

- [基线入口](baseline/README.md)
- [模块地图](baseline/module-map.md)
- [运行流程](baseline/runtime-flows.md)
- [状态与存储](baseline/storage-and-state.md)
- [测试与发布门禁](baseline/test-and-release-gates.md)
- [风险热点](baseline/risk-hotspots.md)

## Active Plans

| Plan | Status | Current Phase | Last Landed | Next Target |
| --- | --- | --- | --- | --- |
| [Pro 发布安全](plans/pro-release-safety/README.md) | In Progress | v0.1.278 已同步，继续落地两段式升级 | v0.1.278 本地 merge（`c3b80cd3`） | 提交并推送适配；READY 后等待迁移发布二次确认 |

低承诺想法记录在 [ideas/inbox.md](ideas/inbox.md)。
