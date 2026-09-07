# Release Contract

Date: 2026-09-03

发布分为上游人工同步、验证、镜像调度、远端预检和部署阶段。上游合并必须人工处理冲突并验证二开，不能直接安装官方 Release。首选的 `make pro-upgrade` 必须自动读取当前完整 fork HEAD 和线上 app 基线，构建或复用匹配的 Pro 镜像，生成绑定两端提交的发布清单，并停在生产切换前。它输出的 ready state 绑定 HEAD、基线、镜像摘要、清单哈希和数据库变更数。

部署只接受 Pro GHCR 摘要。用户二次确认后才能单独调用 `make pro-upgrade-release PRO_EXECUTE=1`；该入口重新验证 ready state，并在任何发布写操作前确认线上 app 仍是准备时的基线。正式部署与独立远端预检复用同一脚本，核对服务器拉取权限、镜像标签以及 app/database 的 Compose 归属。Pro 的 `BuildType=pro` 禁止后端使用 `TokenFlux/TokenRouter` 官方更新或回退 API，前端不提供原生回退入口。

发布必须输出准确失败阶段。无迁移时，应用切换后的验证失败可恢复旧镜像。有迁移时，发布需要显式授权且禁止自动应用回退，恢复必须按升级前数据库备份执行。盈利 sidecar 是独立部署组件，只验证事实源中登记的路由，不随 app 重建。
