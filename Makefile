.PHONY: build build-backend build-frontend build-datamanagementd test test-backend test-frontend test-frontend-critical test-datamanagementd secret-scan pro-verify pro-release-manifest pro-image pro-deploy-check pro-release

PNPM ?= npx --yes pnpm@9
PRO_RELEASE_MANIFEST ?= build/pro-release-manifest.json

FRONTEND_CRITICAL_VITEST := \
	src/api/__tests__/client.spec.ts \
	src/api/__tests__/tokenRefresh.spec.ts \
	src/views/admin/orders/__tests__/AdminOrdersView.spec.ts \
	src/views/auth/__tests__/LinuxDoCallbackView.spec.ts \
	src/views/auth/__tests__/WechatCallbackView.spec.ts \
	src/views/user/__tests__/PaymentView.spec.ts \
	src/views/user/__tests__/PaymentResultView.spec.ts \
	src/components/user/profile/__tests__/ProfileEditForm.spec.ts \
	src/components/user/profile/__tests__/ProfileInfoCard.spec.ts \
	src/views/admin/__tests__/SettingsView.spec.ts \
	src/composables/__tests__/useQoderOAuth.spec.ts \
	src/components/account/__tests__/CreateAccountModal.qoder.spec.ts \
	src/views/admin/__tests__/AccountsView.qoderCreate.spec.ts

# 一键编译前后端
build: build-backend build-frontend

# 编译后端（复用 backend/Makefile）
build-backend:
	@$(MAKE) -C backend build

# 编译前端（需要已安装依赖）
build-frontend:
	@$(PNPM) --dir frontend run build

# 编译 datamanagementd（宿主机数据管理进程）
build-datamanagementd:
	@cd datamanagement && go build -o datamanagementd ./cmd/datamanagementd

# 运行测试（后端 + 前端）
test: test-backend test-frontend

test-backend:
	@$(MAKE) -C backend test

test-frontend:
	@$(PNPM) --dir frontend run lint:check
	@$(PNPM) --dir frontend run typecheck
	@$(MAKE) test-frontend-critical

test-frontend-critical:
	@$(PNPM) --dir frontend exec vitest run $(FRONTEND_CRITICAL_VITEST)

test-datamanagementd:
	@cd datamanagement && go test ./...

secret-scan:
	@python3 tools/secret_scan.py

# Pro 发布门禁：正式运行要求干净 main 且 HEAD 与 origin/main 一致。
pro-verify:
	@GOTOOLCHAIN=auto python3 tools/pro_release_guard.py

# PRO_BASE_REF 必须是当前线上应用对应的源码提交。
pro-release-manifest:
	@test -n "$(PRO_BASE_REF)" || (echo "PRO_BASE_REF is required" >&2; exit 2)
	@GOTOOLCHAIN=auto python3 tools/pro_release_guard.py --base-ref "$(PRO_BASE_REF)" --output "$(PRO_RELEASE_MANIFEST)"

# 完整构建本地不可变 Pro 镜像；不会推送或部署。
pro-image:
	@bash tools/pro-image.sh "$(PRO_RELEASE_MANIFEST)"

# 只检查部署参数，不连接 Pro 服务器。
pro-deploy-check:
	@test -n "$(PRO_IMAGE_DIGEST)" || (echo "PRO_IMAGE_DIGEST is required" >&2; exit 2)
	@bash tools/pro-deploy.sh --manifest "$(PRO_RELEASE_MANIFEST)" --image "$(PRO_IMAGE_DIGEST)" $(if $(filter 1,$(PRO_ALLOW_MIGRATIONS)),--allow-migrations,)

# 唯一 Pro 应用发布入口；必须双重显式提供镜像摘要和 PRO_EXECUTE=1。
pro-release:
	@test -n "$(PRO_IMAGE_DIGEST)" || (echo "PRO_IMAGE_DIGEST is required" >&2; exit 2)
	@test "$(PRO_EXECUTE)" = "1" || (echo "PRO_EXECUTE=1 is required" >&2; exit 2)
	@bash tools/pro-deploy.sh --manifest "$(PRO_RELEASE_MANIFEST)" --image "$(PRO_IMAGE_DIGEST)" $(if $(filter 1,$(PRO_ALLOW_MIGRATIONS)),--allow-migrations,) --execute
