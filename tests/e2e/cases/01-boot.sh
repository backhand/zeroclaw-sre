#!/usr/bin/env bash
# Spec acceptance 1 — Boot.
#
# The pod comes up, /health answers, and no credential is visible anywhere it
# should not be: not in the pod spec, not in the rendered config on the PVC.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

say "01 — boot, health, and no leaked secrets"

if wait_for 240 "deployment available" \
     kubectl -n "$E2E_NS" wait --for=condition=Available deploy/zeroclaw-sre --timeout=5s; then
  pass "pod became Ready"
else
  fail "pod never became Ready"
  k describe pod -l app.kubernetes.io/name=zeroclaw-sre | tail -40
  k logs deploy/zeroclaw-sre -c zeroclaw --tail=60 || true
  exit 1
fi

# /health, from inside the pod: the Service deliberately does not publish 42617
# to the cluster, so this is the only place it is reachable.
if in_agent curl -sf --max-time 5 http://127.0.0.1:42617/health >/dev/null; then
  pass "gateway /health returns 200"
else
  fail "gateway /health did not answer"
fi

if kubectl -n "$E2E_SINK_NS" exec deploy/chat-sink -- \
     wget -q -O - --timeout=5 "http://zeroclaw-sre.${E2E_NS}.svc.cluster.local:9099/healthz" \
     2>/dev/null | grep -q '"status":"ok"'; then
  pass "alert adapter /healthz is ok through the Service"
else
  fail "alert adapter /healthz unreachable or not ok"
fi

# The pod spec must reference secrets, never contain them.
podyaml="$(k get pod -l app.kubernetes.io/name=zeroclaw-sre -o yaml)"
leaked=0
for pattern in 'sk-ant-[A-Za-z0-9_-]{10,}' 'xox[baprs]-[A-Za-z0-9-]{10,}' 'ghp_[A-Za-z0-9]{20,}'; do
  if grep -Eq "$pattern" <<<"$podyaml"; then
    fail "credential-shaped string matching /$pattern/ found in the pod spec"
    leaked=1
  fi
done
[ "$leaked" -eq 0 ] && pass "no credential material in the pod spec (Secret refs only)"

if grep -q 'secretKeyRef\|secretRef' <<<"$podyaml"; then
  pass "credentials arrive by Secret reference"
else
  fail "pod spec has no Secret reference — where are the credentials coming from?"
fi

# The rendered config lives on the PVC (it has to: ZeroClaw has one install
# root and all durable state hangs off it), so what matters is that it carries
# no credential *values*. See NOTES.md §2.
#
# Comments are stripped first: the template deliberately documents which env
# var feeds `api_key`, `bot_token` and `paired_tokens`, and matching that prose
# would fail on the explanation rather than on a secret.
rendered="$(in_agent cat /data/config.toml | sed 's/[[:space:]]*#.*$//')"

leaked=0
# A credential field assigned a non-empty value, in any form TOML allows.
for field in api_key bot_token app_token paired_tokens secret; do
  if grep -qE "^[[:space:]]*${field}[[:space:]]*=[[:space:]]*[\"\[][^\"]" <<<"$rendered"; then
    fail "rendered config assigns a value to '$field'"
    leaked=1
  fi
done
# ...and no credential-shaped literal anywhere, assigned or not.
for pattern in 'sk-ant-[A-Za-z0-9_-]{8,}' 'xox[baprs]-[A-Za-z0-9-]{8,}' 'xai-[A-Za-z0-9]{8,}' 'ghp_[A-Za-z0-9]{8,}'; do
  if grep -qE -- "$pattern" <<<"$rendered"; then
    fail "rendered config contains a literal matching /$pattern/"
    leaked=1
  fi
done
[ "$leaked" -eq 0 ] && pass "rendered config on the PVC assigns no credential value"

# The stronger claim: nothing anywhere on the volume, not just in the config.
if in_agent sh -c 'grep -rlE "sk-ant-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|xai-[A-Za-z0-9]{8,}|ghp_[A-Za-z0-9]{8,}" /data 2>/dev/null | head -1' | grep -q .; then
  fail "a credential-shaped literal exists somewhere on the PVC"
else
  pass "no credential-shaped literal anywhere on the PVC"
fi

# shellcheck disable=SC2016  # $(...) must be evaluated inside the container, not here
if in_agent sh -c 'test "$(stat -c %a /data/config.toml)" = 600'; then
  pass "rendered config is mode 0600"
else
  fail "rendered config is not mode 0600"
fi

# The distro payload must have landed in the workspace.
if in_agent test -f /data/workspace/skills/k3s-admin/SKILL.md \
   && in_agent test -f /data/workspace/sops/crashloop-sweep/SOP.toml; then
  pass "distro workspace payload synced from the image"
else
  fail "workspace payload missing after boot"
fi

# The executor binary must be present and the shell must have no GitHub
# credential — that pairing is the whole custody argument.
if in_agent test -x /usr/local/bin/mcp-executor; then
  pass "the MCP executor is installed"
else
  fail "/usr/local/bin/mcp-executor is missing"
fi

if in_agent sh -c 'grep -A12 shell_env_passthrough /data/config.toml | grep -q "\"GH_TOKEN\""'; then
  fail "GH_TOKEN is still in shell_env_passthrough — the shell can reach GitHub directly"
else
  pass "GH_TOKEN is not passed to the shell (only the executor holds it)"
fi

summary
