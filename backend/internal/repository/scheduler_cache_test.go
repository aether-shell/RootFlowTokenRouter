package repository

import (
	"testing"

	"github.com/TokenFlux/TokenRouter/internal/service"
	"github.com/stretchr/testify/require"
)

func TestFilterSchedulerCredentialsKeepsSubscriptionPlanType(t *testing.T) {
	filtered := filterSchedulerCredentials(map[string]any{
		"plan_type":     "plus",
		"access_token":  "secret-access-token",
		"refresh_token": "secret-refresh-token",
	})

	require.Equal(t, "plus", filtered["plan_type"])
	require.NotContains(t, filtered, "access_token")
	require.NotContains(t, filtered, "refresh_token")
}

func TestSchedulerMetadataAccountKeepsOpenAISubscriptionIdentity(t *testing.T) {
	account := service.Account{
		ID:       24,
		Platform: service.PlatformOpenAI,
		Type:     service.AccountTypeOAuth,
		Credentials: map[string]any{
			"plan_type":    "plus",
			"access_token": "secret-access-token",
		},
	}

	metadata := buildSchedulerMetadataAccount(account)

	require.True(t, metadata.IsOpenAIChatGPTSubscription())
	require.Empty(t, metadata.GetCredential("access_token"))
}

func TestFilterSchedulerExtraKeepsOpenAIClientPolicyTLSSettings(t *testing.T) {
	filtered := filterSchedulerExtra(map[string]any{
		"openai_client_policy":           service.OpenAIClientPolicyTLSRouterMatchedOnly,
		"openai_oauth_client_policy":     service.OpenAIClientPolicyCodexOnly,
		"codex_cli_only":                 true,
		"codex_cli_only_allowed_clients": []any{"claude_code"},
		"enable_tls_fingerprint":         true,
		"tls_fingerprint_profile_id":     int64(2),
		"tls_fingerprint_router_id":      int64(7),
		"unrelated_secret":               "drop-me",
	})

	require.Equal(t, service.OpenAIClientPolicyTLSRouterMatchedOnly, filtered["openai_client_policy"])
	require.Equal(t, int64(2), filtered["tls_fingerprint_profile_id"])
	require.Equal(t, int64(7), filtered["tls_fingerprint_router_id"])
	require.NotContains(t, filtered, "unrelated_secret")
}
