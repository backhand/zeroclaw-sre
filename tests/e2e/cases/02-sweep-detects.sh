#!/usr/bin/env bash
# Spec acceptance 2 — the sweep names a broken workload, with evidence.
#
# Assertions run against the chat sink: what the agent actually tried to send
# to its channels. Needs a real model call.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

say "02 — sweep detects a broken workload and posts a digest"
require_llm "sweep detection" || { summary; exit 0; }

kk apply -f "$E2E_ROOT/manifests/broken-workload.yaml"
info "waiting for the fixtures to actually be broken"
wait_for 180 "broken-image in ImagePullBackOff" bash -c \
  "kubectl -n $E2E_APP_NS get pods -l app=broken-image -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' | grep -qE 'ImagePullBackOff|ErrImagePull'" || true
wait_for 180 "broken-crashloop restarting" bash -c \
  "kubectl -n $E2E_APP_NS get pods -l app=broken-crashloop -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | grep -qE '[1-9]'" || true

sink_reset
info "triggering the sweep out of band (the cron schedule is too slow for CI)"
trigger_agent 'Run the crashloop-sweep SOP now: call sop_execute with name "crashloop-sweep" and follow its steps. Namespaces in scope: e2e-apps.' >/dev/null

if wait_for 300 "a digest to arrive at the sink" bash -c \
     "kubectl -n $E2E_SINK_NS exec deploy/chat-sink -- sh -c 'cat /tmp/messages.ndjson 2>/dev/null' | grep -qi 'broken'"; then
  pass "the sweep posted something naming a broken workload"
else
  fail "no digest mentioning a broken workload arrived"
  k logs deploy/zeroclaw-sre -c zeroclaw --tail=80 || true
  summary; exit 1
fi

msgs="$(sink_messages)"

if grep -qiE 'broken-image|broken-crashloop' <<<"$msgs"; then
  pass "digest names the workload"
else
  fail "digest does not name either broken workload"
fi

if grep -qiE 'ImagePullBackOff|ErrImagePull|CrashLoopBackOff' <<<"$msgs"; then
  pass "digest carries the container reason"
else
  fail "digest has no reason string"
fi

if grep -qiE 'e2e-marker|connection refused|manifest|not found|pull' <<<"$msgs"; then
  pass "digest carries log or event evidence"
else
  fail "digest has no log/event evidence"
fi

if grep -qi 'e2e-apps' <<<"$msgs"; then
  pass "digest is namespace-qualified"
else
  fail "digest does not name the namespace"
fi

# Both channels: the sink stands in for Slack (delivery) and Discord
# (send_via), so two sends for one sweep is the signal.
count="$(grep -ci 'broken' <<<"$msgs" || true)"
if [ "${count:-0}" -ge 2 ]; then
  pass "the digest was sent to both channels ($count sends)"
else
  info "only $count send(s) recorded — Discord fanout via send_via may not have fired"
  fail "digest did not reach both channels"
fi

summary
