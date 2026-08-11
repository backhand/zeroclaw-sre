#!/usr/bin/env bash
# k3d acceptance suite for zeroclaw-k3s-sre (spec §11).
#
#   make e2e                        # everything runnable without credentials
#   ANTHROPIC_API_KEY=... make e2e  # plus every case that needs a real model
#   GH_TOKEN=... E2E_GH_REPO=owner/throwaway make e2e   # plus ticket dedupe
#
# Chat is not mocked at the Slack/Discord API level. Instead the agent's
# outbound channel is switched to ZeroClaw's generic webhook channel, pointed
# at an in-cluster sink, and the cases assert on what the agent tried to send —
# which is what the spec permits when live tokens are unavailable.
#
# Environment:
#   K3D_CLUSTER     cluster name              (default zeroclaw-sre-e2e)
#   IMAGE_REF       image to test             (default zeroclaw-sre:dev)
#   KEEP_CLUSTER=1  leave the cluster running for debugging
#   CASES="01 07"   run a subset
set -euo pipefail

E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_ROOT/../.." && pwd)"
# shellcheck source=lib.sh
source "$E2E_ROOT/lib.sh"

K3D_CLUSTER="${K3D_CLUSTER:-zeroclaw-sre-e2e}"
IMAGE_REF="${IMAGE_REF:-zeroclaw-sre:dev}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need k3d
need kubectl
need docker
need python3

cleanup() {
  local rc=$?
  if [ "$KEEP_CLUSTER" = "1" ]; then
    echo
    echo "KEEP_CLUSTER=1 — leaving '$K3D_CLUSTER' up."
    echo "  kubectl --context k3d-$K3D_CLUSTER -n $E2E_NS logs deploy/zeroclaw-sre -c zeroclaw"
    echo "  k3d cluster delete $K3D_CLUSTER"
  else
    echo
    echo "tearing down cluster $K3D_CLUSTER"
    k3d cluster delete "$K3D_CLUSTER" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

say "creating k3d cluster '$K3D_CLUSTER'"
if k3d cluster list 2>/dev/null | grep -q "^$K3D_CLUSTER "; then
  info "cluster already exists, reusing it"
else
  # metrics-server is what `kubectl top` (and therefore rightsizing) needs; it
  # is part of a stock k3s, so leave it enabled.
  k3d cluster create "$K3D_CLUSTER" \
    --agents 1 \
    --wait \
    --timeout 180s
fi
kubectl config use-context "k3d-$K3D_CLUSTER" >/dev/null

say "loading $IMAGE_REF into the cluster"
if ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  info "image not found locally; building it"
  (cd "$REPO_ROOT" && docker build -t "$IMAGE_REF" .)
fi
k3d image import "$IMAGE_REF" -c "$K3D_CLUSTER"

say "deploying"
kubectl apply -f "$REPO_ROOT/deploy/namespace.yaml"
kubectl apply -f "$REPO_ROOT/deploy/rbac.yaml"
kubectl apply -f "$E2E_ROOT/manifests/chat-sink.yaml"
kubectl apply -f "$E2E_ROOT/manifests/broken-workload.yaml"   # creates the e2e-apps namespace

# Write RoleBinding for the test namespace, so case 07 can prove the boundary
# is per-namespace rather than absent.
make -s -C "$REPO_ROOT" rolebindings ALLOWED_NAMESPACES="$E2E_APP_NS" | kubectl apply -f -

# Test credentials. The LLM key is real when supplied and obviously-fake
# otherwise; every case that needs a real one checks first and skips.
kubectl -n "$E2E_NS" create secret generic zeroclaw-sre \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-sk-ant-e2e-placeholder}" \
  --from-literal=SLACK_BOT_TOKEN="xoxb-e2e" \
  --from-literal=SLACK_APP_TOKEN="xapp-e2e" \
  --from-literal=DISCORD_BOT_TOKEN="e2e" \
  --from-literal=ZC_WEBHOOK_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
  --from-literal=ZC_GATEWAY_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
  --from-literal=GH_TOKEN="${GH_TOKEN:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$E2E_NS" create configmap zeroclaw-sre \
  --from-literal=SLACK_CHANNEL_IDS="C0E2E000000" \
  --from-literal=DISCORD_GUILD_ID="000000000000000000" \
  --from-literal=DISCORD_CHANNEL_IDS="000000000000000001" \
  --from-literal=ZC_ALLOWED_USERS="UE2EOPERATOR" \
  --from-literal=ALLOWED_NAMESPACES="$E2E_APP_NS" \
  --from-literal=GH_REPO="${E2E_GH_REPO:-}" \
  --from-literal=ZC_MODEL="${ZC_MODEL:-claude-sonnet-4-5}" \
  --from-literal=ZC_SANDBOX_BACKEND="none" \
  --from-literal=SWEEP_CRON="0 3 * * *" \
  --from-literal=RIGHTSIZE_CRON="0 4 * * 1" \
  --from-literal=HEARTBEAT_CRON="0 5 * * *" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$REPO_ROOT/deploy/pvc.yaml"
kubectl apply -f "$REPO_ROOT/deploy/service.yaml"

# Patch the Deployment for the test run:
#   - the locally-built image, never pulled;
#   - chat routed to the sink instead of Slack and Discord, via ZeroClaw's
#     env-override layer (values land in memory only, exactly like the real
#     credentials do).
python3 - "$REPO_ROOT/deploy/deployment.yaml" <<'PY' > /tmp/zc-e2e-deployment.yaml
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
spec = doc["spec"]["template"]["spec"]
sink = "http://chat-sink.e2e-sink.svc.cluster.local:8080/messages"
overrides = {
    "ZEROCLAW_channels__webhook__sink__enabled": "true",
    "ZEROCLAW_channels__webhook__sink__port": "42619",
    "ZEROCLAW_channels__webhook__sink__send_url": sink,
    "ZEROCLAW_channels__webhook__sink__send_method": "POST",
    "ZEROCLAW_channels__slack__ops__enabled": "false",
    "ZEROCLAW_channels__discord__ops__enabled": "false",
    "ZEROCLAW_agents__sre__channels": '["webhook.sink"]',
    "ZEROCLAW_peer_groups__ops_slack__channel": "webhook.sink",
    "ZEROCLAW_cron__sweep__delivery__channel": "webhook.sink",
    "ZEROCLAW_cron__rightsize__delivery__channel": "webhook.sink",
    "ZEROCLAW_cron__heartbeat__delivery__channel": "webhook.sink",
}
for c in spec["containers"]:
    c["imagePullPolicy"] = "Never"
    if c["name"] == "zeroclaw":
        c.setdefault("env", []).extend({"name": k, "value": v} for k, v in overrides.items())
yaml.safe_dump(doc, sys.stdout, default_flow_style=False)
PY

IMG="$IMAGE_REF" python3 - <<'PY'
import os, re
p = "/tmp/zc-e2e-deployment.yaml"
s = open(p).read()
s = re.sub(r"image: ghcr\.io/backhand/zeroclaw-sre[^\s]*", "image: " + os.environ["IMG"], s)
open(p, "w").write(s)
PY

kubectl apply -f /tmp/zc-e2e-deployment.yaml
kubectl -n "$E2E_SINK_NS" rollout status deploy/chat-sink --timeout=120s
kubectl -n "$E2E_NS" rollout status deploy/zeroclaw-sre --timeout=300s || {
  kubectl -n "$E2E_NS" describe pod -l app.kubernetes.io/name=zeroclaw-sre | tail -50
  kubectl -n "$E2E_NS" logs deploy/zeroclaw-sre -c zeroclaw --tail=100 || true
  echo "deployment never became ready" >&2
  exit 1
}

llm_available || {
  say "NOTE"
  info "ANTHROPIC_API_KEY is not set. Cases needing a real model call will be"
  info "skipped, not faked: 02, 03, 05, 06 and part of 04 and 08."
}

failed=()
for case_file in "$E2E_ROOT"/cases/*.sh; do
  name="$(basename "$case_file" .sh)"
  if [ -n "${CASES:-}" ] && ! grep -qw "${name%%-*}" <<<"$CASES"; then
    continue
  fi
  if bash "$case_file"; then :; else failed+=("$name"); fi
done

say "acceptance summary"
if [ ${#failed[@]} -eq 0 ]; then
  info "all selected cases passed"
  exit 0
fi
for f in "${failed[@]}"; do info "FAILED: $f"; done
exit 1
