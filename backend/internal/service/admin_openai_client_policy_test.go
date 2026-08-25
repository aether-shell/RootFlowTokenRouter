package service

import (
	"context"
	"testing"

	"github.com/TokenFlux/TokenRouter/internal/model"
	"github.com/stretchr/testify/require"
)

func TestAdminServiceNormalizeOpenAIClientPolicyAccount(t *testing.T) {
	enabledRouter := &model.TLSFingerprintRouter{
		ID:      7,
		Name:    "Codex clients",
		Enabled: true,
		Rules: []model.TLSFingerprintRouterRule{{
			Name:                    "Codex",
			Enabled:                 true,
			MatchType:               model.TLSRouterMatchPrefix,
			Pattern:                 "codex_",
			TLSFingerprintProfileID: 0,
		}},
	}
	disabledRouter := &model.TLSFingerprintRouter{ID: 8, Name: "disabled", Enabled: false}
	svc := &adminServiceImpl{
		tlsFPRouterService:  newTLSFingerprintRouterTestService(enabledRouter, disabledRouter),
		tlsFPProfileService: &TLSFingerprintProfileService{},
	}

	t.Run("API Key TLS-only 合法配置", func(t *testing.T) {
		account := &Account{
			Platform: PlatformOpenAI,
			Type:     AccountTypeAPIKey,
			Extra: map[string]any{
				"openai_client_policy":      OpenAIClientPolicyTLSRouterMatchedOnly,
				"enable_tls_fingerprint":    true,
				"tls_fingerprint_router_id": int64(7),
			},
		}

		require.NoError(t, svc.normalizeOpenAIClientPolicyAccount(context.Background(), account))
		require.Equal(t, OpenAIClientPolicyTLSRouterMatchedOnly, account.Extra["openai_client_policy"])
	})

	t.Run("TLS-only 未开启 TLS 时拒绝", func(t *testing.T) {
		account := &Account{
			Platform: PlatformOpenAI,
			Type:     AccountTypeAPIKey,
			Extra: map[string]any{
				"openai_client_policy":      OpenAIClientPolicyTLSRouterMatchedOnly,
				"tls_fingerprint_router_id": int64(7),
			},
		}

		require.Error(t, svc.normalizeOpenAIClientPolicyAccount(context.Background(), account))
	})

	t.Run("TLS-only 路由器禁用时拒绝", func(t *testing.T) {
		account := &Account{
			Platform: PlatformOpenAI,
			Type:     AccountTypeAPIKey,
			Extra: map[string]any{
				"openai_client_policy":      OpenAIClientPolicyTLSRouterMatchedOnly,
				"enable_tls_fingerprint":    true,
				"tls_fingerprint_router_id": int64(8),
			},
		}

		require.Error(t, svc.normalizeOpenAIClientPolicyAccount(context.Background(), account))
	})

	t.Run("未知策略拒绝", func(t *testing.T) {
		account := &Account{
			Platform: PlatformOpenAI,
			Type:     AccountTypeAPIKey,
			Extra:    map[string]any{"openai_client_policy": "unknown"},
		}

		require.Error(t, svc.normalizeOpenAIClientPolicyAccount(context.Background(), account))
	})

	t.Run("关闭 TLS 清理 Profile 和 router", func(t *testing.T) {
		account := &Account{
			Platform: PlatformOpenAI,
			Type:     AccountTypeAPIKey,
			Extra: map[string]any{
				"openai_client_policy":       OpenAIClientPolicyAny,
				"enable_tls_fingerprint":     false,
				"tls_fingerprint_profile_id": int64(3),
				"tls_fingerprint_router_id":  int64(7),
			},
		}

		require.NoError(t, svc.normalizeOpenAIClientPolicyAccount(context.Background(), account))
		_, hasProfile := account.Extra["tls_fingerprint_profile_id"]
		_, hasRouter := account.Extra["tls_fingerprint_router_id"]
		require.False(t, hasProfile)
		require.False(t, hasRouter)
	})
}

func TestNormalizeOpenAIClientPolicyPatch(t *testing.T) {
	extra := map[string]any{"openai_oauth_client_policy": OpenAIClientPolicyCodexOnly}
	require.NoError(t, normalizeOpenAIClientPolicyPatch(extra))
	require.Equal(t, OpenAIClientPolicyCodexOnly, extra["openai_client_policy"])
	require.Equal(t, true, extra["codex_cli_only"])
}
