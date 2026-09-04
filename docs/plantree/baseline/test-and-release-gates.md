# Test And Release Gates

Pro 门禁由 `deploy/pro/customizations.yaml`、`tools/pro_release_guard.py`、`tools/pro-image.sh`、`tools/pro-remote-check.sh` 和 `tools/pro-deploy.sh` 共同实现。镜像工作流必须由 `make pro-image-dispatch` 自动读取准确 HEAD；远端镜像、OCI 标签和 Compose 归属预检必须先于任何发布写操作。`health=200` 仅属于存活检查，不能代替二开测试、镜像来源、commit、运行时二开标识和业务页面校验。
