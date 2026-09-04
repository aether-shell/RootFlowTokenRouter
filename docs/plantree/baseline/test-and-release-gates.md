# Test And Release Gates

Pro 门禁由 `deploy/pro/customizations.yaml`、`tools/pro_release_guard.py`、`tools/pro-image.sh` 和 `tools/pro-deploy.sh` 共同实现。`health=200` 仅属于存活检查，不能代替二开测试、镜像来源和 commit 校验。
