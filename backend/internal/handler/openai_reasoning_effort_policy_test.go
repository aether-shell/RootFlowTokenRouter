package handler

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/TokenFlux/TokenRouter/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"github.com/tidwall/gjson"
)

// TestApplyOpenAIReasoningEffortPolicyForRequest 验证分组可自行决定不兼容档位的目标值。
func TestApplyOpenAIReasoningEffortPolicyForRequest_MapsConfiguredNoneForAstra(t *testing.T) {
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", nil)

	apiKey := &service.APIKey{
		Group: &service.Group{
			Platform: service.PlatformOpenAI,
			ReasoningEffortMappings: []service.ReasoningEffortMapping{{
				From:      "none",
				To:        "low",
				MatchType: "exact",
				Model:     "gpt-6-astra",
			}},
		},
	}

	body := []byte(`{"model":"gpt-6-astra","reasoning":{"effort":"none"}}`)
	updated, changed, err := applyOpenAIReasoningEffortPolicyForRequest(c, apiKey, body)

	require.NoError(t, err)
	require.True(t, changed)
	require.Equal(t, "low", gjson.GetBytes(updated, "reasoning.effort").String())
	requested := service.RequestedReasoningEffortFromContext(c.Request.Context())
	require.NotNil(t, requested)
	require.Equal(t, "none", *requested)
	forwarded := "low"
	result := &service.OpenAIForwardResult{ReasoningEffort: &forwarded}
	stampOpenAIRequestedReasoningEffort(result, c)
	require.NotNil(t, result.RequestedReasoningEffort)
	require.Equal(t, "none", *result.RequestedReasoningEffort)
}
