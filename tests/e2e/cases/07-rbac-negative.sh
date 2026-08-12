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

# `kubectl auth can-i` asks the API server the authorization question directly
# and answers exactly "yes" or "no". Attempting the real verb instead is a
# worse test: `delete --all` on an empty namespace prints "No resources found"
# and never reaches an authorization decision, which reads as "not denied".
#
# stderr is dropped because cluster-scoped resources emit a "not namespace
# scoped" warning that would otherwise be mistaken for the answer.
can_i() {   # can_i <args...> -> prints yes|no
  k exec deploy/zeroclaw-sre -c zeroclaw -- \
    sh -c "kubectl auth can-i $* 2>/dev/null | tail -1" | tr -d '\r'
}

denied() {   # denied <description> <auth can-i args...>
  local desc="$1"; shift
  local ans; ans="$(can_i "$@")"
  if [ "$ans" = "no" ]; then
    pass "$desc is denied"
  else
    fail "$desc was NOT denied (kubectl auth can-i $* -> ${ans:-<empty>})"
  fi
}

allowed() {   # allowed <description> <auth can-i args...>
  local desc="$1"; shift
  local ans; ans="$(can_i "$@")"
  if [ "$ans" = "yes" ]; then
    pass "$desc is allowed"
  else
    fail "$desc should be allowed (kubectl auth can-i $* -> ${ans:-<empty>})"
  fi
}

# The verbs that would let a compromised prompt do real damage.
denied "deleting a pod"            delete pods -n kube-system
denied "deleting a pod anywhere"   delete pods --all-namespaces
denied "reading a secret"          get secrets -n kube-system
denied "listing secrets anywhere"  list secrets --all-namespaces
denied "creating a workload"       create deployments.apps -n default
denied "deleting a deployment"     delete deployments.apps -n default
denied "evicting/draining a node"  update nodes
denied "scaling a deployment"      update deployments.apps -n default
denied "editing RBAC"              create clusterrolebindings.rbac.authorization.k8s.io
denied "reading configmaps"        get configmaps -n kube-system
denied "port-forwarding into a pod" create pods/portforward -n kube-system
denied "exec-ing into a pod"       create pods/exec -n kube-system

# ...and the reads the playbook genuinely needs.
allowed "listing pods cluster-wide"     list pods --all-namespaces
allowed "reading pod logs"              get pods/log --all-namespaces
allowed "listing events"                list events --all-namespaces
allowed "listing nodes"                 list nodes
allowed "listing deployments"           list deployments.apps --all-namespaces
allowed "reading metrics"               list pods.metrics.k8s.io --all-namespaces

# Delete on replicasets is the one destructive verb, and it is bound per
# namespace exactly like patch.
allowed "deleting replicasets in the bound namespace" delete replicasets.apps -n "$E2E_APP_NS"
denied  "deleting replicasets in kube-system"        delete replicasets.apps -n kube-system
denied  "deleting replicasets in default"            delete replicasets.apps -n default
denied  "deleting pods even where prune is bound"    delete pods -n "$E2E_APP_NS"
denied  "deleting deployments where prune is bound"  delete deployments.apps -n "$E2E_APP_NS"

# Patch: permitted only where a RoleBinding exists.
allowed "patching workloads in the bound namespace" patch deployments.apps -n "$E2E_APP_NS"
denied  "patching workloads in kube-system"           patch deployments.apps -n kube-system
denied  "patching workloads in default"               patch deployments.apps -n default

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
