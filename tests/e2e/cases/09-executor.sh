#!/usr/bin/env bash
# The MCP executor: the component that actually enforces the mutation rules.
#
# Driven directly over stdio rather than through the agent. That is deliberate —
# these are the assertions that must hold regardless of what any model decides,
# and routing them through an LLM would make them slow, expensive, and
# non-deterministic without testing anything extra. The agent-facing half (that
# the tools are visible and gated) is case 10.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

say "09 — MCP executor enforces the mutation rules"

# Drive the executor over stdin. `kubectl exec -i` pipes straight into the
# process, which avoids nesting JSON inside a remote `sh -c` string.
mcp() {   # mcp <<< frames -> raw stdout
  k exec -i deploy/zeroclaw-sre -c zeroclaw -- /usr/local/bin/mcp-executor 2>/dev/null
}

# exec_tool <tool> <json-args> -> "OK: text" or "ERROR: text"
exec_tool() {
  local tool="$1" args="$2"
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}" \
  | mcp | python3 -c "
import json,sys
for line in sys.stdin:
    try: d=json.loads(line)
    except Exception: continue
    r=d.get('result') or {}
    if 'content' in r:
        print(('ERROR: ' if r.get('isError') else 'OK: ') + r['content'][0]['text'])
"
}

# refuses <description> <tool> <args> <expected substring>
refuses() {
  local desc="$1" tool="$2" args="$3" want="$4" out
  out="$(exec_tool "$tool" "$args" || true)"
  if grep -q "^ERROR:" <<<"$out" && grep -qF "$want" <<<"$out"; then
    pass "$desc"
  else
    fail "$desc — got: ${out:-<no output>}"
  fi
}

# ── the handshake ────────────────────────────────────────────────
tools="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | mcp || true)"
if grep -q '"protocolVersion":"2024-11-05"' <<<"$tools"; then
  pass "speaks MCP 2024-11-05"
else
  fail "handshake did not return the expected protocol version"
fi
for t in prune_replicaset file_issue; do
  if grep -q "\"$t\"" <<<"$tools"; then pass "advertises $t"; else fail "does not advertise $t"; fi
done

# ── argument validation: the real boundary ───────────────────────
# Each of these must be refused before anything reaches kubectl.
refuses "rejects a shell metacharacter in the name" \
  prune_replicaset '{"namespace":"'"$E2E_APP_NS"'","name":"rs;rm -rf /"}' "not a valid name"
refuses "rejects path traversal" \
  prune_replicaset '{"namespace":"'"$E2E_APP_NS"'","name":"../../etc/passwd"}' "not a valid name"
refuses "rejects a flag as a name" \
  prune_replicaset '{"namespace":"'"$E2E_APP_NS"'","name":"--all"}' "not a valid name"
refuses "rejects a namespace outside ALLOWED_NAMESPACES" \
  prune_replicaset '{"namespace":"kube-system","name":"anything"}' "not in ALLOWED_NAMESPACES"
refuses "rejects a repo that is not owner/repo" \
  file_issue '{"repo":"https://github.com/o/r","title":"t","body":"b"}' "not an owner/repo"
refuses "rejects an empty issue body" \
  file_issue '{"repo":"o/r","title":"t","body":""}' "body is required"

# ── the safety check that matters ────────────────────────────────
live="$(kk -n "$E2E_APP_NS" get rs -o json \
  | python3 -c "import json,sys; rs=[i['metadata']['name'] for i in json.load(sys.stdin)['items'] if (i['spec'].get('replicas') or 0)>0]; print(rs[0] if rs else '')")"
if [ -n "$live" ]; then
  refuses "refuses a ReplicaSet that is still serving traffic" \
    prune_replicaset "{\"namespace\":\"$E2E_APP_NS\",\"name\":\"$live\"}" "it is serving traffic"
else
  fail "no live ReplicaSet in $E2E_APP_NS to test the refusal against"
fi

# ── and the operation it exists to perform ───────────────────────
prunable="$(k exec deploy/zeroclaw-sre -c zeroclaw -- \
  sh /data/workspace/skills/k3s-admin/bin/prune-rs.sh list "$E2E_APP_NS" 2 2>/dev/null \
  | head -1 | cut -f1 || true)"
prunable="$(tr -d '\r\n' <<<"$prunable")"

if [ -z "$prunable" ]; then
  fail "no prunable ReplicaSet in $E2E_APP_NS — the fixture did not produce revision history"
else
  before="$(kk -n "$E2E_APP_NS" get rs "$prunable" -o name 2>/dev/null || true)"
  out="$(exec_tool prune_replicaset "{\"namespace\":\"$E2E_APP_NS\",\"name\":\"$prunable\"}" || true)"
  if grep -q "^OK: deleted" <<<"$out"; then
    pass "deletes a genuinely superseded ReplicaSet ($prunable)"
  else
    fail "could not prune $prunable — got: ${out:-<no output>}"
  fi

  if [ -n "$before" ] && wait_for 60 "the ReplicaSet to disappear" bash -c \
       "! kubectl -n $E2E_APP_NS get rs $prunable >/dev/null 2>&1"; then
    pass "the object is actually gone from the cluster"
  else
    fail "$prunable still exists after a successful prune"
  fi
fi

# ── every call is on the record, refusals included ───────────────
today="$(date -u +%Y-%m-%d)"
audit="$(k exec deploy/zeroclaw-sre -c zeroclaw -- \
  cat "/data/workspace/receipts/executor-${today}.ndjson" 2>/dev/null || true)"
if grep -q '"tool":"prune_replicaset"' <<<"$audit"; then
  pass "calls are written to the executor audit log"
else
  fail "no executor audit entries found"
fi
if grep -q '"ok":false' <<<"$audit"; then
  pass "refusals are audited too, not just successes"
else
  fail "refusals are missing from the audit log"
fi

summary
