package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func call(t *testing.T, s *server, name, args string) toolResult {
	t.Helper()
	return s.call(name, json.RawMessage(args))
}

func newTestServer(t *testing.T) *server {
	t.Helper()
	t.Setenv("ZC_EXECUTOR_AUDIT_DIR", t.TempDir())
	return newServer()
}

// The protocol handshake has to match what ZeroClaw's client sends, or the
// server is invisible however correct its tools are.
func TestInitializeHandshake(t *testing.T) {
	s := newTestServer(t)
	resp := s.handle(&request{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "initialize"})
	if resp.Error != nil {
		t.Fatalf("initialize errored: %+v", resp.Error)
	}
	got, _ := json.Marshal(resp.Result)
	for _, want := range []string{`"protocolVersion":"2024-11-05"`, `"tools":{}`, "zeroclaw-sre-executor"} {
		if !strings.Contains(string(got), want) {
			t.Errorf("initialize result missing %s\ngot: %s", want, got)
		}
	}
}

func TestToolsListAdvertisesBothTools(t *testing.T) {
	s := newTestServer(t)
	resp := s.handle(&request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "tools/list"})
	got, _ := json.Marshal(resp.Result)
	for _, want := range []string{"prune_replicaset", "file_issue", "inputSchema", "additionalProperties"} {
		if !strings.Contains(string(got), want) {
			t.Errorf("tools/list missing %s", want)
		}
	}
}

// A notification carries no id and must produce no response, or the client's
// pending-request map desynchronises.
func TestNotificationsAreNotAnswered(t *testing.T) {
	var req request
	if err := json.Unmarshal([]byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}`), &req); err != nil {
		t.Fatal(err)
	}
	if len(req.ID) != 0 {
		t.Fatalf("expected no id, got %s", req.ID)
	}
}

func TestUnknownMethodAndTool(t *testing.T) {
	s := newTestServer(t)
	resp := s.handle(&request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "does/not/exist"})
	if resp.Error == nil || resp.Error.Code != -32601 {
		t.Errorf("want method-not-found, got %+v", resp.Error)
	}
	if res := call(t, s, "no_such_tool", `{}`); !res.IsError {
		t.Error("unknown tool should be a tool error")
	}
}

// Argument validation is the component's reason to exist: these are the inputs
// that must never reach kubectl or gh.
func TestPruneRejectsBadInput(t *testing.T) {
	t.Setenv("ALLOWED_NAMESPACES", "demo")
	s := newTestServer(t)

	cases := []struct{ name, args, wants string }{
		{"missing namespace", `{"name":"rs-1"}`, "namespace is required"},
		{"missing name", `{"namespace":"demo"}`, "name is required"},
		{"namespace not in scope", `{"namespace":"kube-system","name":"rs-1"}`, "not in ALLOWED_NAMESPACES"},
		{"shell metacharacter", `{"namespace":"demo","name":"rs-1;rm -rf /"}`, "not a valid name"},
		{"path traversal", `{"namespace":"demo","name":"../../etc/passwd"}`, "not a valid name"},
		{"uppercase", `{"namespace":"demo","name":"RS-1"}`, "not a valid name"},
		{"flag injection", `{"namespace":"demo","name":"--all"}`, "not a valid name"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := call(t, s, "prune_replicaset", tc.args)
			if !res.IsError {
				t.Fatalf("expected refusal, got success: %s", res.Content[0].Text)
			}
			if !strings.Contains(res.Content[0].Text, tc.wants) {
				t.Errorf("want %q, got %q", tc.wants, res.Content[0].Text)
			}
		})
	}
}

// With no writable namespace configured, nothing is prunable — the same rule
// the skill states, enforced where the model cannot restate it.
func TestPruneRefusesWhenScopeEmpty(t *testing.T) {
	t.Setenv("ALLOWED_NAMESPACES", "")
	s := newTestServer(t)
	res := call(t, s, "prune_replicaset", `{"namespace":"demo","name":"rs-1"}`)
	if !res.IsError || !strings.Contains(res.Content[0].Text, "no namespace is writable") {
		t.Errorf("got %q", res.Content[0].Text)
	}
}

func TestFileIssueRejectsBadInput(t *testing.T) {
	t.Setenv("GH_TOKEN", "ghp_test")
	s := newTestServer(t)

	cases := []struct{ name, args, wants string }{
		{"url not owner/repo", `{"repo":"https://github.com/o/r","title":"t","body":"b"}`, "not an owner/repo"},
		{"missing owner", `{"repo":"repo","title":"t","body":"b"}`, "not an owner/repo"},
		{"metacharacter", `{"repo":"o/r;whoami","title":"t","body":"b"}`, "not an owner/repo"},
		{"empty title", `{"repo":"o/r","title":"  ","body":"b"}`, "title is required"},
		{"empty body", `{"repo":"o/r","title":"t","body":""}`, "body is required"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := call(t, s, "file_issue", tc.args)
			if !res.IsError {
				t.Fatal("expected refusal")
			}
			if !strings.Contains(res.Content[0].Text, tc.wants) {
				t.Errorf("want %q, got %q", tc.wants, res.Content[0].Text)
			}
		})
	}
}

// Without a token the tool refuses rather than shelling out to a `gh` that
// would fail with something less legible.
func TestFileIssueNeedsAToken(t *testing.T) {
	t.Setenv("GH_TOKEN", "")
	s := newTestServer(t)
	res := call(t, s, "file_issue", `{"repo":"o/r","title":"t","body":"b"}`)
	if !res.IsError || !strings.Contains(res.Content[0].Text, "no GH_TOKEN") {
		t.Errorf("got %q", res.Content[0].Text)
	}
}

// Refusals must be recorded too — a refused delete is exactly the event worth
// finding later.
func TestRefusalsAreAudited(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ZC_EXECUTOR_AUDIT_DIR", dir)
	t.Setenv("ALLOWED_NAMESPACES", "demo")
	s := newServer()

	call(t, s, "prune_replicaset", `{"namespace":"kube-system","name":"rs-1"}`)

	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) == 0 {
		t.Fatalf("no audit file written: %v", err)
	}
	data, _ := os.ReadFile(dir + "/" + entries[0].Name())
	line := string(data)
	for _, want := range []string{`"tool":"prune_replicaset"`, `"ok":false`, "kube-system"} {
		if !strings.Contains(line, want) {
			t.Errorf("audit line missing %s\ngot: %s", want, line)
		}
	}
}
