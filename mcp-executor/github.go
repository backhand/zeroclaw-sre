package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
	"time"
)

// file_issue opens one GitHub issue.
//
// The point is custody, not convenience. GH_TOKEN is removed from
// `shell_env_passthrough`, so the agent's own `gh` invocations have no
// credential; only this process inherits one from the daemon. A prompt-injected
// agent can therefore file an issue and nothing else — it cannot push code,
// close issues, delete a repository, or read a private repo it was never
// pointed at.
//
// The repo is chosen by the caller because ownership is per workload (see the
// k3s-admin skill's repo-map.sh). Validated, never interpolated into a shell.
func fileIssueTool() *tool {
	return &tool{
		name: "file_issue",
		description: "Open ONE GitHub issue. The only GitHub write available: this process holds the " +
			"token, the agent's shell does not. Resolve the repo with the k3s-admin skill's " +
			"repo-map.sh before calling, and never guess it.",
		schema: map[string]any{
			"type":     "object",
			"required": []string{"repo", "title", "body"},
			"properties": map[string]any{
				"repo": map[string]any{
					"type":        "string",
					"description": "owner/repo, from repo-map.sh resolve.",
				},
				"title": map[string]any{"type": "string", "description": "Issue title."},
				"body":  map[string]any{"type": "string", "description": "Issue body, markdown. Include the fingerprint: line."},
				"labels": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Labels to apply. Defaults to zeroclaw-sre.",
				},
			},
			"additionalProperties": false,
		},
		run: runFileIssue,
	}
}

func runFileIssue(raw json.RawMessage) toolResult {
	var args struct {
		Repo   string   `json:"repo"`
		Title  string   `json:"title"`
		Body   string   `json:"body"`
		Labels []string `json:"labels"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return fail("could not parse arguments: %v", err)
	}

	if !ghRepoRe.MatchString(args.Repo) {
		return fail("refused: %q is not an owner/repo", args.Repo)
	}
	if strings.TrimSpace(args.Title) == "" {
		return fail("refused: title is required")
	}
	if strings.TrimSpace(args.Body) == "" {
		return fail("refused: body is required — an issue with no evidence is noise")
	}
	if len(args.Title) > 250 {
		return fail("refused: title is %d characters, max 250", len(args.Title))
	}
	if len(args.Body) > 60000 {
		return fail("refused: body is %d characters, max 60000", len(args.Body))
	}
	if os.Getenv("GH_TOKEN") == "" {
		return fail("refused: no GH_TOKEN in this process — ticket filing is not configured")
	}

	labels := args.Labels
	if len(labels) == 0 {
		labels = []string{"zeroclaw-sre"}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// The body goes in on stdin rather than as an argument: it carries log
	// excerpts, and an argument list is the wrong place for arbitrary text.
	cmd := exec.CommandContext(ctx, "gh", "issue", "create",
		"--repo", args.Repo, "--title", args.Title, "--body-file", "-")
	for _, l := range labels {
		cmd.Args = append(cmd.Args, "--label", l)
	}
	cmd.Stdin = strings.NewReader(args.Body)

	out, err := cmd.Output()
	if err != nil {
		return fail("could not create the issue in %s: %v", args.Repo, cleanExecErr(err))
	}

	// gh prints the issue URL on success.
	url := strings.TrimSpace(string(out))
	if i := strings.LastIndex(url, "\n"); i >= 0 {
		url = strings.TrimSpace(url[i+1:])
	}
	return ok("filed %s", url)
}

// Small shims so the other files do not each import `errors`/`strings`.
func errorsAs(err error, target any) bool { return errors.As(err, target) }

func trimTo(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
