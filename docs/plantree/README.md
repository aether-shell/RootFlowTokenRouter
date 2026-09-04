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
| [Pro 发布安全](plans/pro-release-safety/README.md) | Done | Pro v0.1.276 复盘已转化为发布门禁 | 自动镜像调度、远端预检和分阶段失败输出（当前提交） | 配置 GHCR 只读部署凭据；下次发布以 `aa2d857c` 为线上基线 |

低承诺想法记录在 [ideas/inbox.md](ideas/inbox.md)。
