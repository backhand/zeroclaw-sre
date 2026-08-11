package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var version = "0.1.0"

// A tool is a mutating operation with a schema narrow enough that it cannot
// express the thing you did not authorise.
type tool struct {
	name        string
	description string
	schema      map[string]any
	run         func(args json.RawMessage) toolResult
}

type server struct {
	tools map[string]*tool
	audit *auditLog
}

func newServer() *server {
	s := &server{tools: map[string]*tool{}, audit: newAuditLog()}
	s.register(pruneReplicaSetTool())
	s.register(fileIssueTool())
	return s
}

func (s *server) register(t *tool) { s.tools[t.name] = t }

func (s *server) toolNames() string {
	names := make([]string, 0, len(s.tools))
	for n := range s.tools {
		names = append(names, n)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

func (s *server) descriptors() []map[string]any {
	names := make([]string, 0, len(s.tools))
	for n := range s.tools {
		names = append(names, n)
	}
	sort.Strings(names)

	out := make([]map[string]any, 0, len(names))
	for _, n := range names {
		t := s.tools[n]
		out = append(out, map[string]any{
			"name":        t.name,
			"description": t.description,
			"inputSchema": t.schema,
		})
	}
	return out
}

func (s *server) call(name string, args json.RawMessage) toolResult {
	t, found := s.tools[name]
	if !found {
		return fail("no such tool: %s", name)
	}
	started := time.Now()
	res := t.run(args)
	// Every attempt is recorded, including refusals — a refused delete is
	// exactly the event worth being able to find later.
	s.audit.record(name, args, res, time.Since(started))
	return res
}

// ── validation ───────────────────────────────────────────────────
//
// Rejecting bad input here is the point of the whole component: these patterns
// are what stop an argument from being a shell fragment, a path, or another
// object entirely.

var (
	dns1123  = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	ghRepoRe = regexp.MustCompile(`^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`)
)

func validName(kind, v string) error {
	if v == "" {
		return fmt.Errorf("%s is required", kind)
	}
	if len(v) > 253 {
		return fmt.Errorf("%s is too long", kind)
	}
	if !dns1123.MatchString(v) {
		return fmt.Errorf("%q is not a valid %s (lowercase alphanumerics and '-')", v, kind)
	}
	return nil
}

// allowedNamespace enforces the same write scope the agent is told about, in
// code. RBAC is still the real boundary — this makes the refusal explicit and
// legible instead of surfacing as an API-server 403.
func allowedNamespace(ns string) error {
	scope := strings.TrimSpace(os.Getenv("ALLOWED_NAMESPACES"))
	if scope == "" {
		return fmt.Errorf("ALLOWED_NAMESPACES is empty — no namespace is writable")
	}
	for _, s := range strings.Split(scope, ",") {
		if strings.TrimSpace(s) == ns {
			return nil
		}
	}
	return fmt.Errorf("namespace %q is not in ALLOWED_NAMESPACES (%s)", ns, scope)
}

// ── audit ────────────────────────────────────────────────────────

type auditLog struct{ dir string }

func newAuditLog() *auditLog {
	dir := os.Getenv("ZC_EXECUTOR_AUDIT_DIR")
	if dir == "" {
		dir = "/data/workspace/receipts"
	}
	return &auditLog{dir: dir}
}

// record appends one line per call. Append-only and outside the model's reach:
// the agent has no tool that writes here, so it cannot edit its own history.
func (a *auditLog) record(toolName string, args json.RawMessage, res toolResult, took time.Duration) {
	entry := map[string]any{
		"ts":       time.Now().UTC().Format(time.RFC3339),
		"executor": version,
		"tool":     toolName,
		"args":     json.RawMessage(args),
		"ok":       !res.IsError,
		"took_ms":  took.Milliseconds(),
	}
	if len(res.Content) > 0 {
		entry["result"] = res.Content[0].Text
	}

	line, err := json.Marshal(entry)
	if err != nil {
		log.Printf("audit: could not encode entry: %v", err)
		return
	}
	if err := os.MkdirAll(a.dir, 0o755); err != nil {
		log.Printf("audit: %v", err)
		return
	}
	path := filepath.Join(a.dir, "executor-"+time.Now().UTC().Format("2006-01-02")+".ndjson")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		log.Printf("audit: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(line, '\n')); err != nil {
		log.Printf("audit: %v", err)
	}
	// Mirrored to stderr so it also lands in `kubectl logs`, which is the first
	// place anyone looks and needs no volume access.
	log.Printf("%s %s -> ok=%v", toolName, strings.TrimSpace(string(args)), !res.IsError)
}
