// mcp-executor exposes the agent's *mutating* cluster and GitHub operations as
// typed MCP tools, so each one can be approved on its own.
//
// # Why this exists
//
// ZeroClaw gates approvals per tool. Every mutation and every read currently
// share one tool — `shell` — so a gate is either on everything (an approval for
// each `kubectl get`, which buries a Slack channel) or on nothing. Neither is a
// security posture. A separate tool per mutation makes the gate match the risk:
//
//	always_ask   = ["k8s__prune_replicaset", "gh__file_issue"]
//	auto_approve = ["shell"]        # reads stay silent
//
// A typed tool is also stronger than a command allowlist. `allowed_commands`
// can permit `kubectl` but cannot express "delete only a superseded, empty
// ReplicaSet"; prune_replicaset(namespace, name) *cannot represent* anything
// else. The validation lives in code that the model cannot rephrase.
//
// Protocol: JSON-RPC 2.0 over stdio, newline-delimited, MCP 2024-11-05.
// stdout is the protocol channel — every log line goes to stderr, which the
// daemon inherits, so diagnostics land in the pod log without corrupting it.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
)

const protocolVersion = "2024-11-05"

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"` // number or string; echoed verbatim
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// toolResult is MCP's content envelope. `isError` reports a *tool* failure —
// the agent sees the text and can react — as distinct from a JSON-RPC error,
// which means the call itself was malformed.
type toolResult struct {
	Content []textContent `json:"content"`
	IsError bool          `json:"isError,omitempty"`
}

type textContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

func ok(format string, args ...any) toolResult {
	return toolResult{Content: []textContent{{Type: "text", Text: fmt.Sprintf(format, args...)}}}
}

func fail(format string, args ...any) toolResult {
	return toolResult{
		Content: []textContent{{Type: "text", Text: fmt.Sprintf(format, args...)}},
		IsError: true,
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	log.SetPrefix("mcp-executor: ")
	log.SetOutput(os.Stderr)

	srv := newServer()
	log.Printf("ready — tools: %s", srv.toolNames())

	in := bufio.NewScanner(os.Stdin)
	// Tool arguments can carry an issue body; the default 64 KiB token limit is
	// too small for that.
	in.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	out := json.NewEncoder(os.Stdout)

	for in.Scan() {
		line := in.Bytes()
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			log.Printf("dropping unparseable frame: %v", err)
			continue
		}
		// A request without an id is a notification: act on it, answer nothing.
		if len(req.ID) == 0 {
			log.Printf("notification: %s", req.Method)
			continue
		}
		resp := srv.handle(&req)
		if err := out.Encode(resp); err != nil {
			log.Printf("failed to write response: %v", err)
			return
		}
	}
	if err := in.Err(); err != nil && err != io.EOF {
		log.Printf("stdin ended: %v", err)
	}
}

func (s *server) handle(req *request) response {
	resp := response{JSONRPC: "2.0", ID: req.ID}

	switch req.Method {
	case "initialize":
		resp.Result = map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "zeroclaw-sre-executor", "version": version},
		}
	case "ping":
		resp.Result = map[string]any{}
	case "tools/list":
		resp.Result = map[string]any{"tools": s.descriptors()}
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			resp.Error = &rpcError{Code: -32602, Message: "invalid params: " + err.Error()}
			break
		}
		resp.Result = s.call(p.Name, p.Arguments)
	default:
		resp.Error = &rpcError{Code: -32601, Message: "method not found: " + req.Method}
	}
	return resp
}
