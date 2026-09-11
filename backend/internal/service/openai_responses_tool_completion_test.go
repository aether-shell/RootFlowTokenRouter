package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TokenFlux/TokenRouter/internal/config"
	"github.com/TokenFlux/TokenRouter/internal/pkg/apicompat"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"github.com/tidwall/gjson"
)

func completionTestEvent(t *testing.T, typ string, fields map[string]any) string {
	t.Helper()
	fields["type"] = typ
	data, err := json.Marshal(fields)
	require.NoError(t, err)
	return "event: " + typ + "\ndata: " + string(data) + "\n\n"
}

func completionTestItem(custom bool) map[string]any {
	item := map[string]any{"id": "fc_exec", "type": "function_call", "call_id": "call_exec", "name": "shell", "namespace": "functions", "arguments": `{"command":"Get-Location"}`, "status": "completed"}
	if custom {
		item["id"], item["type"], item["input"] = "ctc_exec", "custom_tool_call", "Get-Location"
		delete(item, "arguments")
		delete(item, "namespace")
	}
	return item
}

func completionTestTerminal(t *testing.T, items ...map[string]any) string {
	return completionTestEvent(t, "response.completed", map[string]any{
		"sequence_number": 20, "opaque": map[string]any{"preserved": true},
		"response": map[string]any{"id": "resp_tools", "status": "completed", "model": "gpt-5.6-sol", "output": items,
			"usage": map[string]any{"input_tokens": 17, "output_tokens": 3}},
	})
}

func completionTestPayloads(t *testing.T, stream string) []gjson.Result {
	t.Helper()
	var out []gjson.Result
	for _, line := range strings.Split(stream, "\n") {
		if data, ok := extractOpenAISSEDataLine(line); ok && json.Valid([]byte(data)) {
			out = append(out, gjson.Parse(data))
		}
	}
	return out
}

func completionTestRead(t *testing.T, source io.ReadCloser, account *Account) (string, error) {
	t.Helper()
	body := repairOpenAIResponsesToolCompletionBody(source, account, defaultMaxLineSize)
	defer body.Close()
	data, err := io.ReadAll(body)
	return string(data), err
}

func completionTestAccount() *Account {
	return &Account{ID: 21, Platform: PlatformOpenAI, Type: AccountTypeAPIKey}
}

// 用最终工具项模拟上游漏发所有工具生命周期事件，验证客户端可消费的完整序列。
func TestOpenAIResponsesToolCompletionFromTerminal(t *testing.T) {
	for _, custom := range []bool{false, true} {
		name, inputField, inputEvent := "function", "arguments", "response.function_call_arguments.done"
		if custom {
			name, inputField, inputEvent = "custom", "input", "response.custom_tool_call_input.done"
		}
		t.Run(name, func(t *testing.T) {
			item := completionTestItem(custom)
			input := completionTestTerminal(t, item)
			output, err := completionTestRead(t, io.NopCloser(strings.NewReader(input)), completionTestAccount())
			require.NoError(t, err)
			events := completionTestPayloads(t, output)
			require.Len(t, events, 4)
			for index, typ := range []string{"response.output_item.added", inputEvent, "response.output_item.done", "response.completed"} {
				require.Equal(t, typ, events[index].Get("type").String())
				require.EqualValues(t, 20+index, events[index].Get("sequence_number").Int())
			}
			require.True(t, events[0].Get("output_index").Exists())
			require.Equal(t, "", events[0].Get("item."+inputField).String())
			require.Equal(t, item[inputField], events[1].Get(inputField).String())
			require.Equal(t, item["call_id"], events[2].Get("item.call_id").String())
			require.Equal(t, item["id"], events[1].Get("item_id").String())
			if !custom {
				require.Equal(t, "functions", events[2].Get("item.namespace").String())
			}
			require.True(t, events[3].Get("opaque.preserved").Bool())
			require.EqualValues(t, 17, events[3].Get("response.usage.input_tokens").Int())
		})
	}
}

func TestOpenAIResponsesToolCompletionMissingInputDoneAndDuplicate(t *testing.T) {
	item := completionTestItem(false)
	added := completionTestEvent(t, "response.output_item.added", map[string]any{"sequence_number": 0, "output_index": 0, "item": item})
	done := completionTestEvent(t, "response.output_item.done", map[string]any{"sequence_number": 2, "output_index": 0, "item": item})
	output, err := completionTestRead(t, io.NopCloser(strings.NewReader(added+done+done+completionTestTerminal(t, item))), completionTestAccount())
	require.NoError(t, err)
	events := completionTestPayloads(t, output)
	require.Len(t, events, 4)
	require.Equal(t, "response.function_call_arguments.done", events[1].Get("type").String())
	require.Equal(t, "response.output_item.done", events[2].Get("type").String())
	for index := 1; index < len(events); index++ {
		require.Greater(t, events[index].Get("sequence_number").Int(), events[index-1].Get("sequence_number").Int())
	}
}

func TestOpenAIResponsesToolCompletionParallelTools(t *testing.T) {
	first, second := completionTestItem(false), completionTestItem(true)
	second["call_id"] = "call_patch"
	second["name"] = "apply_patch"
	second["input"] = "*** Begin Patch\n*** End Patch"
	input := completionTestEvent(t, "response.output_item.added", map[string]any{"output_index": 1, "item": second}) +
		completionTestEvent(t, "response.custom_tool_call_input.done", map[string]any{"output_index": 1, "item_id": second["id"], "input": second["input"]}) +
		completionTestTerminal(t, first, second)
	output, err := completionTestRead(t, io.NopCloser(strings.NewReader(input)), completionTestAccount())
	require.NoError(t, err)
	events := completionTestPayloads(t, output)
	var done []gjson.Result
	for _, event := range events {
		if event.Get("type").String() == "response.output_item.done" {
			done = append(done, event)
		}
	}
	require.Len(t, done, 2)
	require.EqualValues(t, 0, done[0].Get("output_index").Int())
	require.Equal(t, "call_exec", done[0].Get("item.call_id").String())
	require.EqualValues(t, 1, done[1].Get("output_index").Int())
	require.Equal(t, "call_patch", done[1].Get("item.call_id").String())
}

func TestOpenAIResponsesToolCompletionCompleteStreamUnchanged(t *testing.T) {
	item := completionTestItem(false)
	input := completionTestEvent(t, "response.output_item.added", map[string]any{"output_index": 0, "item": item}) +
		completionTestEvent(t, "response.function_call_arguments.done", map[string]any{"output_index": 0, "item_id": item["id"], "arguments": item["arguments"]}) +
		completionTestEvent(t, "response.output_item.done", map[string]any{"output_index": 0, "item": item}) + completionTestTerminal(t, item)
	output, err := completionTestRead(t, io.NopCloser(strings.NewReader(input)), completionTestAccount())
	require.NoError(t, err)
	require.Equal(t, input, output)
}

func TestOpenAIResponsesToolCompletionNeverCompletesUnconfirmedInput(t *testing.T) {
	for _, terminal := range []string{"", "data: [DONE]\n\n", "response.failed", "response.incomplete", "error"} {
		t.Run(terminal, func(t *testing.T) {
			item := completionTestItem(false)
			input := completionTestEvent(t, "response.output_item.added", map[string]any{"output_index": 0, "item": item}) +
				completionTestEvent(t, "response.function_call_arguments.delta", map[string]any{"output_index": 0, "item_id": item["id"], "delta": `{"command":"Get-Location"}`})
			if strings.HasPrefix(terminal, "response.") || terminal == "error" {
				input += completionTestEvent(t, terminal, map[string]any{"response": map[string]any{"output": []any{item}}})
			} else {
				input += terminal
			}
			output, err := completionTestRead(t, io.NopCloser(strings.NewReader(input)), completionTestAccount())
			require.NoError(t, err)
			require.Equal(t, input, output)
			require.NotContains(t, output, "response.output_item.done")
		})
	}
}

func TestOpenAIResponsesToolCompletionRejectsInvalidFinalItems(t *testing.T) {
	for _, invalid := range []any{`{"command":`, "", nil, map[string]any{"command": "pwd"}} {
		item := completionTestItem(false)
		item["arguments"] = invalid
		output, err := completionTestRead(t, io.NopCloser(strings.NewReader(completionTestTerminal(t, item))), completionTestAccount())
		require.ErrorContains(t, err, "invalid completed tool item")
		require.NotContains(t, output, "response.output_item.done")
	}
}

// 补齐器在既有参数清理之前运行，仍须兼容上游重复拼接完整 JSON 的情况。
func TestOpenAIResponsesToolCompletionNormalizesRepeatedArguments(t *testing.T) {
	for _, fromItemDone := range []bool{false, true} {
		item := completionTestItem(false)
		arguments := item["arguments"].(string)
		item["arguments"] = arguments + arguments
		input := completionTestTerminal(t, item)
		if fromItemDone {
			input = completionTestEvent(t, "response.output_item.done", map[string]any{"output_index": 0, "item": item}) + input
		}
		output, err := completionTestRead(t, io.NopCloser(strings.NewReader(input)), completionTestAccount())
		require.NoError(t, err)
		events := completionTestPayloads(t, output)
		require.Len(t, events, 4)
		require.Equal(t, arguments, events[1].Get("arguments").String())
		require.Equal(t, arguments, events[2].Get("item.arguments").String())
		require.Equal(t, arguments, events[3].Get("response.output.0.arguments").String())
	}
}

// 缺失 error 与显式 null 均允许成功终态，失败状态或先前错误不能触发补齐。
func TestOpenAIResponsesToolCompletionTerminalSuccessEvidence(t *testing.T) {
	for _, tc := range []struct {
		name     string
		status   string
		error    any
		prefix   string
		complete bool
	}{
		{name: "explicit_null", status: "completed", complete: true},
		{name: "missing_status", complete: true},
		{name: "error_object", status: "completed", error: map[string]any{"message": "failed"}},
		{name: "incomplete_status", status: "incomplete"},
		{name: "failed_status", status: "failed"},
		{name: "prior_failed", status: "completed", prefix: "response.failed"},
		{name: "prior_error", status: "completed", prefix: "error"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := map[string]any{"error": tc.error, "output": []any{completionTestItem(false)}}
			if tc.status != "" {
				response["status"] = tc.status
			}
			input := ""
			if tc.prefix != "" {
				input = completionTestEvent(t, tc.prefix, map[string]any{})
			}
			input += completionTestEvent(t, "response.completed", map[string]any{"response": response})
			output, err := completionTestRead(t, io.NopCloser(strings.NewReader(input)), completionTestAccount())
			require.NoError(t, err)
			if tc.complete {
				require.Contains(t, output, "response.output_item.done")
			} else {
				require.Equal(t, input, output)
			}
		})
	}
}

func TestOpenAIResponsesToolCompletionSSEHeadersAndScope(t *testing.T) {
	input := ": keepalive\n\n" + strings.Replace(completionTestTerminal(t, completionTestItem(false)), `"type":"response.completed",`, "", 1)
	output, err := completionTestRead(t, io.NopCloser(strings.NewReader(strings.TrimRight(input, "\n"))), completionTestAccount())
	require.NoError(t, err)
	require.Contains(t, output, ": keepalive\n\n")
	require.Len(t, completionTestPayloads(t, output), 4)
	for _, account := range []*Account{nil, {Platform: PlatformOpenAI, Type: AccountTypeOAuth}, {Platform: PlatformGrok, Type: AccountTypeAPIKey}} {
		source := io.NopCloser(strings.NewReader(input))
		require.Equal(t, source, repairOpenAIResponsesToolCompletionBody(source, account, defaultMaxLineSize))
	}
}

func TestOpenAIResponsesToolCompletionReadErrorAndClose(t *testing.T) {
	errRead := errors.New("upstream connection reset")
	input := completionTestEvent(t, "response.function_call_arguments.delta", map[string]any{"item_id": "fc_exec", "delta": `{"command":`})
	source := &passthroughFlushTestErrorBody{payload: []byte(input), err: errRead}
	output, err := completionTestRead(t, source, completionTestAccount())
	require.ErrorIs(t, err, errRead)
	require.NotContains(t, output, "response.output_item.done")
	reader, writer := io.Pipe()
	body := repairOpenAIResponsesToolCompletionBody(reader, completionTestAccount(), defaultMaxLineSize)
	require.NoError(t, body.Close())
	_, err = writer.Write([]byte(input))
	require.Error(t, err)
	_ = writer.Close()
}

func TestOpenAIResponsesToolCompletionAfterCustomToolRestoration(t *testing.T) {
	item := completionTestItem(false)
	item["name"], item["arguments"] = "exec", `{"input":"Get-Location"}`
	source := newOpenAIResponsesClientToolStreamBody(io.NopCloser(strings.NewReader(completionTestTerminal(t, item))),
		apicompat.ResponsesClientToolMapping{CustomTools: map[string]bool{"exec": true}}, defaultMaxLineSize)
	output, err := completionTestRead(t, source, completionTestAccount())
	require.NoError(t, err)
	events := completionTestPayloads(t, output)
	require.Len(t, events, 4)
	require.Equal(t, "response.custom_tool_call_input.done", events[1].Get("type").String())
	require.Equal(t, "Get-Location", events[1].Get("input").String())
	require.Equal(t, events[0].Get("item.id").String(), events[2].Get("item.id").String())
}

// 在真实 HTTP SSE 处理器里验证修复后的事件可到达客户端，且用量保持不变。
func TestOpenAIResponsesToolCompletionHTTPHandlers(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, passthrough := range []bool{false, true} {
		name := "managed"
		if passthrough {
			name = "passthrough"
		}
		t.Run(name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(recorder)
			c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
			svc := &OpenAIGatewayService{cfg: &config.Config{Gateway: config.GatewayConfig{MaxLineSize: defaultMaxLineSize}}}
			resp := &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"text/event-stream"}},
				Body: io.NopCloser(strings.NewReader(completionTestTerminal(t, completionTestItem(false))))}
			if passthrough {
				result, err := svc.handleStreamingResponsePassthrough(context.Background(), resp, c, completionTestAccount(), time.Now(), "gpt-5.6-sol", "gpt-5.6-sol")
				require.NoError(t, err)
				require.Equal(t, 17, result.usage.InputTokens)
			} else {
				result, err := svc.handleStreamingResponse(context.Background(), resp, c, completionTestAccount(), time.Now(), "gpt-5.6-sol", "gpt-5.6-sol")
				require.NoError(t, err)
				require.Equal(t, 17, result.usage.InputTokens)
			}
			events := completionTestPayloads(t, recorder.Body.String())
			require.Len(t, events, 4)
			require.Equal(t, "response.function_call_arguments.done", events[1].Get("type").String())
			require.Equal(t, "response.output_item.done", events[2].Get("type").String())
		})
	}
}
