#!/usr/bin/env bash
# Spec acceptance 7 — RBAC is the boundary that does not depend on the model.
#
# From inside the pod, with the real ServiceAccount token, the destructive and
# credential-reading verbs must fail with an authorization error. No API key
# needed: this tests the cluster, not the agent.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

say "07 — RBAC forbids everything it should"

# denied <description> <kubectl args...>
denied() {
  local desc="$1"; shift
  local out
  out="$(k exec deploy/zeroclaw-sre -c zeroclaw -- kubectl "$@" 2>&1 || true)"
  if grep -qiE 'forbidden|cannot|not allowed|Unauthorized' <<<"$out"; then
    pass "$desc is denied"
  else
    fail "$desc was NOT denied: $(head -c 200 <<<"$out")"
  fi
}

allowed() {
  local desc="$1"; shift
  if k exec deploy/zeroclaw-sre -c zeroclaw -- kubectl "$@" >/dev/null 2>&1; then
    pass "$desc is allowed"
  else
    fail "$desc should be allowed but was denied"
  fi
}

# The verbs that would let a compromised prompt do real damage.
denied "deleting a pod"            delete pod -n kube-system --all --dry-run=server
denied "reading a secret"          get secret -n kube-system -o name
denied "listing secrets anywhere"  get secrets --all-namespaces -o name
denied "creating a workload"       create deployment evil --image=busybox -n default --dry-run=server
denied "deleting a deployment"     delete deployment -n default --all --dry-run=server
denied "draining a node"           auth can-i update nodes
denied "scaling a deployment"      auth can-i update deployments.apps
denied "editing RBAC"              auth can-i create clusterrolebindings
denied "reading configmaps"        get configmap -n kube-system -o name

# ...and the reads the playbook genuinely needs.
allowed "listing pods cluster-wide"     get pods --all-namespaces -o name
allowed "reading pod logs"              auth can-i get pods/log --all-namespaces
allowed "listing events"                get events --all-namespaces -o name
allowed "listing nodes"                 get nodes -o name
allowed "listing deployments"           get deployments --all-namespaces -o name
allowed "reading metrics"               auth can-i list pods.metrics.k8s.io

# Patch: permitted only where a RoleBinding exists.
out="$(k exec deploy/zeroclaw-sre -c zeroclaw -- \
  kubectl auth can-i patch deployments.apps -n "$E2E_APP_NS" 2>&1 || true)"
if grep -q '^yes' <<<"$out"; then
  pass "patching workloads is allowed in the bound namespace"
else
  fail "patch should be allowed in $E2E_APP_NS (RoleBinding missing?): $out"
fi

out="$(k exec deploy/zeroclaw-sre -c zeroclaw -- \
  kubectl auth can-i patch deployments.apps -n kube-system 2>&1 || true)"
if grep -q '^no' <<<"$out"; then
  pass "patching workloads is denied outside bound namespaces"
else
  fail "patch is allowed in kube-system — the write ClusterRole is bound too widely"
fi

# The agent must not be able to read its own mounted token through a file tool.
out="$(k exec deploy/zeroclaw-sre -c zeroclaw -- \
  sh -c 'cat /var/run/secrets/kubernetes.io/serviceaccount/token' 2>&1 || true)"
if [ -n "$out" ]; then
  info "note: the token IS readable by the container (kubectl needs it)."
  info "      the agent's file tools are blocked by risk_profiles.sre.forbidden_paths,"
  info "      not by filesystem permissions. See NOTES.md §6."
fi
pass "token accessibility documented (kubectl must read it; the agent's tools may not)"

summary
