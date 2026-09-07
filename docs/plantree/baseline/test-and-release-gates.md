# Test And Release Gates

Pro 门禁由 `deploy/pro/customizations.yaml`、`tools/pro_release_guard.py`、`tools/pro-image.sh`、`tools/pro-upgrade.sh`、`tools/pro-remote-check.sh` 和 `tools/pro-deploy.sh` 共同实现。首选入口 `make pro-upgrade` 自动读取线上基线、构建或复用准确 fork HEAD 的镜像并完成远端预检，但停在生产切换前；`make pro-upgrade-release PRO_EXECUTE=1` 必须在用户二次确认后单独执行。ready state 绑定 HEAD、线上基线、镜像摘要、清单哈希和数据库变更数，远端预检还必须确认线上基线未漂移。`health=200` 仅属于存活检查，不能代替二开测试、镜像来源、commit、运行时二开标识和业务页面校验。Pro 的 `BuildType=pro` 必须禁用官方二进制自更新和回退。
