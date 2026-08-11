#!/usr/bin/env bash
# Spec acceptance 8 — state survives the pod.
#
# Kill the pod; memory, receipts and SOP run state must still be there, and the
# freshly-synced workspace must not have clobbered any of it.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

say "08 — state survives a pod restart"

# Plant a fingerprint through the agent's own memory tool so the check is about
# what the agent knows, not just about files on a disk.
marker="e2e-persist-$(date +%s)"
if llm_available; then
  trigger_agent "Store this in memory verbatim under the key sweep:$marker — first_seen=2026-08-11T00:00:00Z count=3. Reply OK when stored." >/dev/null || true
else
  info "no API key: writing the marker directly to the memory store instead"
  in_agent sh -c "curl -sf -X POST -H 'Content-Type: application/json' \
    -H \"Authorization: Bearer \$ZC_GATEWAY_TOKEN\" \
    -d '{\"key\":\"sweep:$marker\",\"content\":\"first_seen=2026-08-11T00:00:00Z count=3\",\"category\":\"core\"}' \
    http://127.0.0.1:42617/api/memory" >/dev/null || true
fi
sleep 5

before_receipts="$(in_agent sh -c 'cat /data/workspace/receipts/*.ndjson 2>/dev/null | wc -l' || echo 0)"
before_db="$(in_agent sh -c 'ls -1 /data/*.db /data/**/*.db 2>/dev/null | head -5' || true)"
info "receipts before restart: $before_receipts"
[ -n "$before_db" ] && info "sqlite files: $(tr '\n' ' ' <<<"$before_db")"

if in_agent sh -c "grep -rqs '$marker' /data" ; then
  pass "the marker is on the PVC before the restart"
else
  fail "the marker never reached the PVC — nothing to test"
  summary; exit 1
fi

old_pod="$(k get pod -l app.kubernetes.io/name=zeroclaw-sre -o jsonpath='{.items[0].metadata.name}')"
info "deleting pod $old_pod"
k delete pod "$old_pod" --wait=true >/dev/null

if wait_for 240 "the replacement pod to be ready" \
     kubectl -n "$E2E_NS" wait --for=condition=Available deploy/zeroclaw-sre --timeout=5s; then
  pass "a replacement pod came up"
else
  fail "the pod did not come back"
  summary; exit 1
fi

new_pod="$(k get pod -l app.kubernetes.io/name=zeroclaw-sre -o jsonpath='{.items[0].metadata.name}')"
if [ "$new_pod" != "$old_pod" ]; then
  pass "it is genuinely a new pod ($new_pod)"
else
  fail "the pod name did not change"
fi

if in_agent sh -c "grep -rqs '$marker' /data"; then
  pass "the fingerprint survived the restart"
else
  fail "the fingerprint was lost — state is not durable"
fi

after_receipts="$(in_agent sh -c 'cat /data/workspace/receipts/*.ndjson 2>/dev/null | wc -l' || echo 0)"
if [ "${after_receipts:-0}" -ge "${before_receipts:-0}" ]; then
  pass "receipts are intact ($before_receipts -> $after_receipts lines)"
else
  fail "receipts were truncated by the restart ($before_receipts -> $after_receipts)"
fi

# The boot-time workspace sync must replace distro trees without touching state.
if in_agent test -f /data/workspace/skills/k3s-admin/SKILL.md \
   && in_agent test -f /data/workspace/sops/rightsize/SOP.toml; then
  pass "the distro payload was re-synced on boot"
else
  fail "the workspace payload is missing after restart"
fi

if llm_available; then
  out="$(trigger_agent "What do you have stored under the memory key sweep:$marker? Answer with the stored content only." || true)"
  if grep -q 'count=3\|2026-08-11' <<<"$out"; then
    pass "the agent can still recall the prior finding"
  else
    info "agent said: $(head -c 300 <<<"$out")"
    fail "the agent could not recall the stored fingerprint"
  fi
fi

summary
