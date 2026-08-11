#!/usr/bin/env bash
# Spec acceptance 3 — silence is the healthy signal.
#
# With the broken fixtures gone, a sweep must produce no digest at all. Not an
# empty one, not "all clear" — nothing.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

say "03 — a healthy sweep posts nothing"
require_llm "quiet sweep" || { summary; exit 0; }

kk delete -f "$E2E_ROOT/manifests/broken-workload.yaml" --ignore-not-found >/dev/null
info "waiting for the broken pods to disappear"
wait_for 180 "no pods left in $E2E_APP_NS" bash -c \
  "[ -z \"\$(kubectl -n $E2E_APP_NS get pods -o name 2>/dev/null)\" ]" || true

sink_reset
out="$(trigger_agent 'Run the crashloop-sweep SOP now: call sop_execute with name "crashloop-sweep" and follow its steps. Namespaces in scope: e2e-apps.' || true)"
sleep 20   # give any (wrongly) queued outbound send time to land

msgs="$(sink_messages)"
if [ -z "$(tr -d '[:space:]' <<<"$msgs")" ]; then
  pass "no message was sent for a healthy cluster"
else
  fail "the sweep posted something when there was nothing wrong:"
  printf '     %s\n' "$(head -c 500 <<<"$msgs")"
fi

# The agent should still have answered the caller — silence applies to the
# chat channels, not to the operator who asked.
if grep -qi 'SWEEP_CLEAN\|clean\|healthy\|no findings\|nothing' <<<"$out"; then
  pass "the agent reported a clean sweep to the caller"
else
  info "caller response was: $(head -c 300 <<<"$out")"
  fail "the agent did not report a clean result to the caller"
fi

summary
