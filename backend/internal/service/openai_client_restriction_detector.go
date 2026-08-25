package service

import (
	"github.com/TokenFlux/TokenRouter/internal/config"
	"github.com/TokenFlux/TokenRouter/internal/pkg/openai"
	"github.com/gin-gonic/gin"
)

const (
	// CodexClientRestrictionReasonDisabled 表示账号未开启客户端访问限制。
	CodexClientRestrictionReasonDisabled = "openai_oauth_client_policy_any"
	// CodexClientRestrictionReasonMatchedUA 表示请求命中官方客户端 UA 白名单。
	CodexClientRestrictionReasonMatchedUA = "official_client_user_agent_matched"
	// CodexClientRestrictionReasonMatchedOriginator 表示请求命中官方客户端 originator 白名单。
	CodexClientRestrictionReasonMatchedOriginator = "official_client_originator_matched"
	// CodexClientRestrictionReasonMatchedAllowedClient 表示请求命中账号级额外放行的命名客户端预设。
	CodexClientRestrictionReasonMatchedAllowedClient = "allowed_client_matched"
	// CodexClientRestrictionReasonMatchedGlobalAllowedClient 表示请求命中全局额外放行的命名客户端预设。
	CodexClientRestrictionReasonMatchedGlobalAllowedClient = "global_allowed_client_matched"
	// CodexClientRestrictionReasonNotMatchedUA 表示请求未命中官方客户端 UA 白名单。
	CodexClientRestrictionReasonNotMatchedUA = "official_client_user_agent_not_matched"
	// CodexClientRestrictionReasonForceCodexCLI 表示通过 ForceCodexCLI 配置兜底放行。
	CodexClientRestrictionReasonForceCodexCLI = "force_codex_cli_enabled"
	// CodexClientRestrictionReasonMatchedTLSRouter 表示请求命中账号绑定的 TLS 路由器。
	CodexClientRestrictionReasonMatchedTLSRouter = "tls_router_matched"
	// CodexClientRestrictionReasonNotMatchedTLSRouter 表示请求未命中账号绑定的 TLS 路由器。
	CodexClientRestrictionReasonNotMatchedTLSRouter = "tls_router_not_matched"
	// CodexClientRestrictionReasonTLSRouterMissing 表示账号策略要求 TLS 路由器命中，但账号未绑定路由器。
	CodexClientRestrictionReasonTLSRouterMissing = "tls_router_missing"
	// CodexClientRestrictionReasonTLSDisabled 表示账号策略要求 TLS 路由器命中，但未启用 TLS 指纹。
	CodexClientRestrictionReasonTLSDisabled = "tls_fingerprint_disabled"
	// CodexClientRestrictionReasonTLSRouterUnavailable 表示账号绑定的路由器不存在或已禁用。
	CodexClientRestrictionReasonTLSRouterUnavailable = "tls_router_unavailable"
	// CodexClientRestrictionReasonTLSProfileUnavailable 表示命中规则引用的 TLS Profile 无法解析。
	CodexClientRestrictionReasonTLSProfileUnavailable = "tls_profile_unavailable"
)

// CodexClientRestrictionDetectionResult 是 codex_cli_only 统一检测入口结果。
type CodexClientRestrictionDetectionResult struct {
	Enabled bool
	Matched bool
	Reason  string
	Policy  string
}

// CodexClientRestrictionDetector 定义 codex_cli_only 统一检测入口。
type CodexClientRestrictionDetector interface {
	Detect(c *gin.Context, account *Account, globalAllowedClients []string, tlsRouterMatch TLSFingerprintRouterMatchResult) CodexClientRestrictionDetectionResult
}

// OpenAICodexClientRestrictionDetector 为 OpenAI OAuth/API Key 客户端策略的默认实现。
type OpenAICodexClientRestrictionDetector struct {
	cfg *config.Config
}

func NewOpenAICodexClientRestrictionDetector(cfg *config.Config) *OpenAICodexClientRestrictionDetector {
	return &OpenAICodexClientRestrictionDetector{cfg: cfg}
}

func (d *OpenAICodexClientRestrictionDetector) Detect(c *gin.Context, account *Account, globalAllowedClients []string, tlsRouterMatch TLSFingerprintRouterMatchResult) CodexClientRestrictionDetectionResult {
	policy := OpenAIClientPolicyAny
	if account != nil {
		policy = account.GetOpenAIClientPolicy()
	}
	if account == nil || policy == OpenAIClientPolicyAny {
		return CodexClientRestrictionDetectionResult{
			Enabled: false,
			Matched: false,
			Reason:  CodexClientRestrictionReasonDisabled,
			Policy:  policy,
		}
	}

	if policy == OpenAIClientPolicyTLSRouterMatchedOnly {
		if !account.IsTLSFingerprintEnabled() {
			return CodexClientRestrictionDetectionResult{Enabled: true, Reason: CodexClientRestrictionReasonTLSDisabled, Policy: policy}
		}
		if account.GetTLSFingerprintRouterID() <= 0 {
			return CodexClientRestrictionDetectionResult{
				Enabled: true,
				Matched: false,
				Reason:  CodexClientRestrictionReasonTLSRouterMissing,
				Policy:  policy,
			}
		}
		if !tlsRouterMatch.RouterAvailable {
			return CodexClientRestrictionDetectionResult{Enabled: true, Reason: CodexClientRestrictionReasonTLSRouterUnavailable, Policy: policy}
		}
		if tlsRouterMatch.Matched {
			if !tlsRouterMatch.TLSProfileResolved || tlsRouterMatch.TLSProfile == nil {
				return CodexClientRestrictionDetectionResult{Enabled: true, Reason: CodexClientRestrictionReasonTLSProfileUnavailable, Policy: policy}
			}
			return CodexClientRestrictionDetectionResult{
				Enabled: true,
				Matched: true,
				Reason:  CodexClientRestrictionReasonMatchedTLSRouter,
				Policy:  policy,
			}
		}
		return CodexClientRestrictionDetectionResult{
			Enabled: true,
			Matched: false,
			Reason:  CodexClientRestrictionReasonNotMatchedTLSRouter,
			Policy:  policy,
		}
	}

	if d != nil && d.cfg != nil && d.cfg.Gateway.ForceCodexCLI {
		return CodexClientRestrictionDetectionResult{
			Enabled: true,
			Matched: true,
			Reason:  CodexClientRestrictionReasonForceCodexCLI,
			Policy:  policy,
		}
	}

	userAgent := ""
	originator := ""
	if c != nil {
		userAgent = c.GetHeader("User-Agent")
		originator = c.GetHeader("originator")
	}
	if openai.IsCodexOfficialClientRequestStrict(userAgent) {
		return CodexClientRestrictionDetectionResult{
			Enabled: true,
			Matched: true,
			Reason:  CodexClientRestrictionReasonMatchedUA,
			Policy:  policy,
		}
	}
	if openai.IsCodexOfficialClientOriginator(originator) {
		return CodexClientRestrictionDetectionResult{
			Enabled: true,
			Matched: true,
			Reason:  CodexClientRestrictionReasonMatchedOriginator,
			Policy:  policy,
		}
	}

	// 官方客户端白名单未命中时，先尝试账号级额外放行的命名客户端预设（如 Claude Code codex 插件）。
	if allowed := account.GetCodexCLIOnlyAllowedClients(); len(allowed) > 0 &&
		openai.MatchAllowedClients(userAgent, originator, allowed) {
		return CodexClientRestrictionDetectionResult{
			Enabled: true,
			Matched: true,
			Reason:  CodexClientRestrictionReasonMatchedAllowedClient,
			Policy:  policy,
		}
	}

	// 再尝试由更高作用域（全局设置）注入的额外放行客户端列表。
	if len(globalAllowedClients) > 0 &&
		openai.MatchAllowedClients(userAgent, originator, globalAllowedClients) {
		return CodexClientRestrictionDetectionResult{
			Enabled: true,
			Matched: true,
			Reason:  CodexClientRestrictionReasonMatchedGlobalAllowedClient,
			Policy:  policy,
		}
	}

	return CodexClientRestrictionDetectionResult{
		Enabled: true,
		Matched: false,
		Reason:  CodexClientRestrictionReasonNotMatchedUA,
		Policy:  policy,
	}
}
