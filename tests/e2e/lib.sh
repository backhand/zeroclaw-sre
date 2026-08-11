#!/usr/bin/env bash
# Shared helpers for the acceptance suite. Sourced, not executed.

E2E_NS="${E2E_NS:-zeroclaw-sre}"
E2E_APP_NS="${E2E_APP_NS:-e2e-apps}"
E2E_SINK_NS="${E2E_SINK_NS:-e2e-sink}"
E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used by the case scripts that source this file
REPO_ROOT="$(cd "$E2E_ROOT/../.." && pwd)"

_pass=0
_fail=0
_skip=0

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
pass() { printf '   \033[32mPASS\033[0m %s\n' "$*"; _pass=$((_pass + 1)); }
fail() { printf '   \033[31mFAIL\033[0m %s\n' "$*"; _fail=$((_fail + 1)); }
skip() { printf '   \033[33mSKIP\033[0m %s\n' "$*"; _skip=$((_skip + 1)); }

summary() {
  printf '\n%d passed, %d failed, %d skipped\n' "$_pass" "$_fail" "$_skip"
  [ "$_fail" -eq 0 ]
}

k()  { kubectl -n "$E2E_NS" "$@"; }
kk() { kubectl "$@"; }

# Run a command inside the agent container.
in_agent() { k exec deploy/zeroclaw-sre -c zeroclaw -- "$@"; }

# Wait until `cmd` succeeds, or give up. wait_for <seconds> <description> <cmd...>
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local deadline=$(( SECONDS + timeout ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  info "timed out after ${timeout}s waiting for: $desc"
  return 1
}

# Everything the chat sink has received since the suite started.
sink_messages() {
  kubectl -n "$E2E_SINK_NS" exec deploy/chat-sink -- \
    sh -c 'cat /tmp/messages.ndjson 2>/dev/null || true'
}

sink_reset() {
  kubectl -n "$E2E_SINK_NS" exec deploy/chat-sink -- \
    sh -c ': > /tmp/messages.ndjson' || true
}

# sink_contains <pattern> — is `pattern` present in anything the agent sent?
sink_contains() { sink_messages | grep -qiE "$1"; }

# POST an Alertmanager payload to the adapter through the Service.
post_alert() {   # post_alert <secret> <payload-file>
  local secret="$1" file="$2"
  kubectl -n "$E2E_SINK_NS" exec deploy/chat-sink -- \
    sh -c "wget -q -O - --header='Content-Type: application/json' \
      --header='X-Webhook-Secret: ${secret}' \
      --post-data=\"\$(cat <<'EOF'
$(cat "$file")
EOF
)\" http://zeroclaw-sre.${E2E_NS}.svc.cluster.local:9099/alerts 2>&1 || true"
}

# Ask the agent to do something, through the same authenticated gateway path
# the alert adapter uses. The cron schedules are far too slow for a test run,
# and `zeroclaw cron` has no "run now" subcommand, so this is how a case makes
# a scheduled procedure happen on demand — with the same prompt the cron job
# would have sent.
trigger_agent() {   # trigger_agent <message>
  local msg="$1"
  k exec deploy/zeroclaw-sre -c zeroclaw -- sh -c "
    curl -sS --max-time 600 -X POST \
      -H 'Content-Type: application/json' \
      -H \"Authorization: Bearer \$ZC_GATEWAY_TOKEN\" \
      -H \"X-Webhook-Secret: \$ZC_WEBHOOK_SECRET\" \
      -H 'X-Idempotency-Key: e2e-$(date +%s)-$RANDOM' \
      --data-binary @- http://127.0.0.1:42617/webhook <<'PAYLOAD'
$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps({"message": sys.stdin.read()}))')
PAYLOAD
  "
}

llm_available() { [ -n "${ANTHROPIC_API_KEY:-}" ]; }

require_llm() {
  if llm_available; then return 0; fi
  skip "$1 (no ANTHROPIC_API_KEY — this case needs a real model call)"
  return 1
}
