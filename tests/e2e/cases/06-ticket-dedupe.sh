#!/usr/bin/env bash
# Spec acceptance 6 — one issue per problem.
#
# Three consecutive sweeps of the same broken workload must produce exactly one
# issue; a fourth must comment on it rather than open a second.
#
# This needs a throwaway GitHub repo: set GH_TOKEN and E2E_GH_REPO. Without
# them the case is skipped rather than faked — a dedupe test against a mock
# proves nothing about `gh issue list --search`.
#
# The agent files through the k8s__file_issue MCP tool, not `gh`: its shell has
# no GitHub credential at all. The assertions below still use `gh` because the
# *harness* has its own token, and checking the result through a different path
# than the one that wrote it is the stronger test.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

say "06 — repeated findings produce exactly one ticket"

if [ -z "${GH_TOKEN:-}" ] || [ -z "${E2E_GH_REPO:-}" ]; then
  skip "ticket dedupe (set GH_TOKEN and E2E_GH_REPO=<owner/throwaway-repo> to run)"
  summary; exit 0
fi
require_llm "ticket dedupe" || { summary; exit 0; }

issue_count() {
  gh issue list --repo "$E2E_GH_REPO" --label zeroclaw-sre --state open \
    --search "broken-crashloop" --json number --jq 'length'
}

info "cleaning up any issues left by a previous run"
for n in $(gh issue list --repo "$E2E_GH_REPO" --label zeroclaw-sre --state open --json number --jq '.[].number'); do
  gh issue close "$n" --repo "$E2E_GH_REPO" --comment "closed by e2e setup" >/dev/null || true
done

kk apply -f "$E2E_ROOT/manifests/broken-workload.yaml" >/dev/null
wait_for 180 "broken-crashloop restarting" bash -c \
  "kubectl -n $E2E_APP_NS get pods -l app=broken-crashloop -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | grep -qE '[1-9]'" || true

for i in 1 2 3; do
  info "sweep $i of 3"
  sink_reset
  trigger_agent 'Run the crashloop-sweep SOP now: call sop_execute with name "crashloop-sweep" and follow its steps. Namespaces in scope: e2e-apps.' >/dev/null || true
  sleep 15
done

count="$(issue_count)"
if [ "$count" = "1" ]; then
  pass "three sweeps produced exactly one issue"
elif [ "$count" = "0" ]; then
  fail "no issue was filed after three consecutive sweeps"
  summary; exit 1
else
  fail "three sweeps produced $count issues — dedupe is broken"
  summary; exit 1
fi

number="$(gh issue list --repo "$E2E_GH_REPO" --label zeroclaw-sre --state open \
  --search "broken-crashloop" --json number --jq '.[0].number')"
comments_before="$(gh issue view "$number" --repo "$E2E_GH_REPO" --json comments --jq '.comments|length')"

body="$(gh issue view "$number" --repo "$E2E_GH_REPO" --json body --jq .body)"
if grep -qi 'fingerprint:' <<<"$body"; then
  pass "the issue body carries the fingerprint line dedupe searches for"
else
  fail "the issue body has no 'fingerprint:' line — dedupe cannot work reliably"
fi

info "fourth sweep"
trigger_agent 'Run the crashloop-sweep SOP now: call sop_execute with name "crashloop-sweep" and follow its steps. Namespaces in scope: e2e-apps.' >/dev/null || true
sleep 20

if [ "$(issue_count)" = "1" ]; then
  pass "the fourth sweep opened no second issue"
else
  fail "the fourth sweep opened another issue"
fi

comments_after="$(gh issue view "$number" --repo "$E2E_GH_REPO" --json comments --jq '.comments|length')"
if [ "$comments_after" -gt "$comments_before" ]; then
  pass "the fourth sweep commented on the existing issue"
else
  info "comments before=$comments_before after=$comments_after"
  fail "the fourth sweep neither commented nor filed — the finding was dropped"
fi

gh issue close "$number" --repo "$E2E_GH_REPO" --comment "closed by e2e teardown" >/dev/null || true
summary
