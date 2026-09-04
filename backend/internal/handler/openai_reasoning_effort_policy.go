package handler

import (
	"net/http"
	"strings"

	"github.com/TokenFlux/TokenRouter/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/tidwall/gjson"
)

// openAIReasoningEffortPolicyForRequest 返回当前请求最终落到 OpenAI 分组时的策略。
// 复合 Key 已由鉴权中间件投影到具体分组，这里不重新引入旧的复合平台解析层。
func openAIReasoningEffortPolicyForRequest(c *gin.Context, apiKey *service.APIKey) (string, []service.ReasoningEffortMapping, string, bool) {
	if apiKey == nil || apiKey.Group == nil || apiKey.Group.Platform != service.PlatformOpenAI {
		return "", nil, "", false
	}
	if effectiveAPIKeyPlatform(c, apiKey) != service.PlatformOpenAI {
		return "", nil, "", false
	}
	return apiKey.Group.MaxReasoningEffort,
		apiKey.Group.ReasoningEffortMappings,
		apiKey.Group.MaxReasoningEffortOverLimit,
		true
}

// applyOpenAIReasoningEffortPolicyForRequest 在策略改写前保存客户端档位，并执行分组裁决。
func applyOpenAIReasoningEffortPolicyForRequest(c *gin.Context, apiKey *service.APIKey, body []byte) ([]byte, bool, error) {
	model := strings.TrimSpace(gjson.GetBytes(body, "model").String())
	bindRequestedReasoningEffort(c, body, model)
	maxEffort, mappings, overLimit, ok := openAIReasoningEffortPolicyForRequest(c, apiKey)
	if !ok {
		return body, false, nil
	}
	return service.ApplyOpenAIReasoningEffortPolicy(body, maxEffort, mappings, overLimit)
}

// respondOpenAIReasoningEffortPolicyError 将本地超限拒绝转换为 OpenAI 权限错误。
func respondOpenAIReasoningEffortPolicyError(c *gin.Context, err error, write func(*gin.Context, int, string, string)) {
	if c == nil || err == nil || write == nil {
		return
	}
	service.MarkOpsClientBusinessLimited(c, service.OpsClientBusinessLimitedReasonLocalPolicyDenied)
	write(c, http.StatusForbidden, "permission_error", err.Error())
}

// bindOpenAIReasoningEffortPolicyForMessagesRequest 只为显式 output_config.effort
// 绑定策略，避免桥接器为缺省请求补出的 medium 被错误地当作客户端请求。
func bindOpenAIReasoningEffortPolicyForMessagesRequest(c *gin.Context, apiKey *service.APIKey, body []byte) {
	if c == nil || c.Request == nil {
		return
	}
	model := strings.TrimSpace(gjson.GetBytes(body, "model").String())
	bindRequestedReasoningEffort(c, body, model)
	effort := gjson.GetBytes(body, "output_config.effort")
	if !effort.Exists() || effort.Type != gjson.String || strings.TrimSpace(effort.String()) == "" {
		return
	}
	maxEffort, mappings, overLimit, ok := openAIReasoningEffortPolicyForRequest(c, apiKey)
	if !ok {
		return
	}
	ctx := service.WithOpenAIReasoningEffortPolicyForModel(
		c.Request.Context(),
		maxEffort,
		mappings,
		overLimit,
		model,
	)
	c.Request = c.Request.WithContext(ctx)
}
