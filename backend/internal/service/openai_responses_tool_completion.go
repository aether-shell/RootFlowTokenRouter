package service

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/tidwall/gjson"
	"github.com/tidwall/sjson"
)

// 仅保留生命周期标记，不累积命令分片；限制异常上游的工具数量以约束内存。
const openAIResponsesToolCompletionMaxItems = 4096

type openAIResponsesToolCompletionState struct {
	added, inputDone, itemDone bool
	index                      int64
}

type openAIResponsesToolCompletionRepair struct {
	items        map[string]*openAIResponsesToolCompletionState
	nextSequence int64
	resequencing bool
	failed       bool
	bareError    bool
}

func shouldRepairOpenAIResponsesToolCompletion(account *Account) bool {
	return account != nil && account.Platform == PlatformOpenAI && account.Type == AccountTypeAPIKey
}

func (s *OpenAIGatewayService) openAIResponsesToolCompletionLineLimit() int {
	if s.cfg != nil && s.cfg.Gateway.MaxLineSize > 0 {
		return s.cfg.Gateway.MaxLineSize
	}
	return defaultMaxLineSize
}

// API Key 原生 Responses 的普通转发、自动透传和 HTTP→WS 桥共用此修复器。
// OAuth 保留既有行为；EOF、[DONE] 和可解析的参数分片均不构成成功证明。
func repairOpenAIResponsesToolCompletionBody(source io.ReadCloser, account *Account, maxLineSize int) io.ReadCloser {
	if !shouldRepairOpenAIResponsesToolCompletion(account) {
		return source
	}
	repair := &openAIResponsesToolCompletionRepair{items: make(map[string]*openAIResponsesToolCompletionState)}
	reader, writer := io.Pipe()
	body := &responsesClientToolStreamBody{PipeReader: reader, source: source}
	go transformResponsesEventStream(source, writer, maxLineSize, func(payload []byte, eventType string) ([][]byte, bool, error) {
		if gjson.GetBytes(payload, "type").String() == "" && eventType != "" {
			var err error
			payload, err = sjson.SetBytes(payload, "type", eventType)
			if err != nil {
				return nil, false, err
			}
		}
		return repair.repairEvent(payload)
	})
	return body
}

func (r *openAIResponsesToolCompletionRepair) state(id string, index int64) (*openAIResponsesToolCompletionState, error) {
	if state := r.items[id]; state != nil {
		if state.index != index {
			return nil, fmt.Errorf("Responses tool completion: item changed output_index")
		}
		return state, nil
	}
	if len(r.items) >= openAIResponsesToolCompletionMaxItems {
		return nil, fmt.Errorf("Responses tool completion: too many tool items")
	}
	state := &openAIResponsesToolCompletionState{index: index}
	// gjson 的字符串可能引用整个 SSE 载荷，复制 ID 避免间接保留命令正文。
	r.items[strings.Clone(id)] = state
	return state, nil
}

// 只从 output_item.done 或成功终止事件中的完整 output 补齐工具生命周期。
// 保留未知字段、namespace、call_id 和 usage，补发后统一调整后续事件序号。
func (r *openAIResponsesToolCompletionRepair) repairEvent(payload []byte) ([][]byte, bool, error) {
	// 先沿用既有重复参数修正，避免在下游清理之前拒绝可恢复的完整参数。
	payload, _ = normalizeOpenAIResponsesFunctionCallArguments(payload)
	root := gjson.ParseBytes(payload)
	typ := root.Get("type").String()
	sequence := root.Get("sequence_number").Int()
	if sequence > r.nextSequence {
		r.nextSequence = sequence
	}
	var before [][]byte
	drop := false
	var err error
	switch typ {
	case "error":
		r.bareError = true
	case "response.failed", "response.incomplete", "response.cancelled", "response.canceled":
		r.failed = true
	case "response.output_item.added":
		item := root.Get("item")
		if isOpenAICompletionTool(item) && item.Get("id").String() != "" {
			var state *openAIResponsesToolCompletionState
			state, err = r.state(item.Get("id").String(), root.Get("output_index").Int())
			if err == nil {
				drop = state.added || state.itemDone
				state.added = true
			}
		}
	case "response.function_call_arguments.done", "response.custom_tool_call_input.done":
		if id := root.Get("item_id").String(); id != "" {
			var state *openAIResponsesToolCompletionState
			state, err = r.state(id, root.Get("output_index").Int())
			if err == nil {
				drop = state.inputDone || state.itemDone
				state.inputDone = true
			}
		}
	case "response.output_item.done":
		item := root.Get("item")
		if !r.failed && !r.bareError && isOpenAICompletionTool(item) {
			before, drop, err = r.completeTool(item, root.Get("output_index").Int(), true)
		}
	case "response.completed", "response.done":
		status := root.Get("response.status").String()
		if !r.failed && !r.bareError && (status == "" || status == "completed") && root.Get("response.error").Type == gjson.Null {
			// 裸 error 后的事件由下游错误处理器裁决，不在其终态裁决前补发工具。
			for index, item := range root.Get("response.output").Array() {
				if !isOpenAICompletionTool(item) {
					continue
				}
				var events [][]byte
				events, _, err = r.completeTool(item, int64(index), false)
				if err != nil {
					break
				}
				before = append(before, events...)
			}
		}
	}
	if err != nil {
		return nil, false, err
	}
	if len(before) > 0 || drop {
		r.resequencing = true
	}
	if !drop {
		before = append(before, payload)
	}
	if !r.resequencing {
		r.nextSequence++
		return before, false, nil
	}
	for index, event := range before {
		before[index], err = sjson.SetBytes(event, "sequence_number", r.nextSequence)
		if err != nil {
			return nil, false, err
		}
		r.nextSequence++
	}
	return before, true, nil
}

func isOpenAICompletionTool(item gjson.Result) bool {
	return item.Get("type").String() == "function_call" || item.Get("type").String() == "custom_tool_call"
}

func (r *openAIResponsesToolCompletionRepair) completeTool(item gjson.Result, index int64, incomingDone bool) ([][]byte, bool, error) {
	status := item.Get("status").String()
	if status != "" && status != "completed" {
		return nil, false, nil
	}
	id, name, callID := item.Get("id").String(), item.Get("name").String(), item.Get("call_id").String()
	// 已关闭的工具允许终态仅携带摘要，不要求上游再次回传完整参数。
	if state := r.items[id]; state != nil && state.itemDone && state.index == index {
		return nil, incomingDone, nil
	}
	field, doneType := "arguments", "response.function_call_arguments.done"
	if item.Get("type").String() == "custom_tool_call" {
		field, doneType = "input", "response.custom_tool_call_input.done"
	}
	value := item.Get(field)
	if strings.TrimSpace(id) == "" || strings.TrimSpace(name) == "" || strings.TrimSpace(callID) == "" || index < 0 || value.Type != gjson.String ||
		(field == "arguments" && !json.Valid([]byte(value.String()))) {
		return nil, false, fmt.Errorf("Responses tool completion: invalid completed tool item")
	}
	state, err := r.state(id, index)
	if err != nil {
		return nil, false, err
	}
	var events [][]byte
	emit := func(event map[string]any) error {
		encoded, err := json.Marshal(event)
		if err == nil {
			events = append(events, encoded)
		}
		return err
	}
	if !state.added {
		// 缺少 added 时从已确认的最终项恢复元数据，声明阶段的输入仍为空。
		added, err := sjson.Set(item.Raw, field, "")
		if err != nil {
			return nil, false, err
		}
		added, err = sjson.Set(added, "status", "in_progress")
		if err != nil {
			return nil, false, err
		}
		if err = emit(map[string]any{"type": "response.output_item.added", "output_index": index, "item": json.RawMessage(added)}); err != nil {
			return nil, false, err
		}
		state.added = true
	}
	if !state.inputDone {
		if err = emit(map[string]any{"type": doneType, "output_index": index, "item_id": id, "call_id": callID, "name": name, field: value.String()}); err != nil {
			return nil, false, err
		}
		state.inputDone = true
	}
	if !incomingDone {
		if err = emit(map[string]any{"type": "response.output_item.done", "output_index": index, "item": json.RawMessage(item.Raw)}); err != nil {
			return nil, false, err
		}
	}
	state.itemDone = true
	return events, false, nil
}
