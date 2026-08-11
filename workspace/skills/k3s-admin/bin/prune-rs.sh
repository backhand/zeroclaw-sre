#!/bin/sh
# Which superseded ReplicaSets are safe to remove?
#
#   prune-rs.sh list  <namespace> [keep]     -> TSV of prunable ReplicaSets
#   prune-rs.sh prune <namespace> <name>     -> delete one, re-checking first
#
# A ReplicaSet is prunable only when ALL of these hold:
#
#   1. it is owned by a Deployment      — orphans are somebody else's business
#   2. spec.replicas == 0               — it is not running anything
#   3. status.replicas == 0             — and nothing is still terminating
#   4. it is not the current revision   — never delete what is serving traffic
#   5. it is outside the newest `keep`  — rollback history is the whole point
#
# `keep` defaults to 3, so `kubectl rollout undo` still works several steps
# back. Kubernetes already enforces its own ceiling per Deployment via
# .spec.revisionHistoryLimit (default 10); this trims below that, it does not
# replace it.
#
# The decision lives here rather than in a prompt because it is arithmetic on
# revision numbers, and getting it wrong deletes a running workload's pods.
#
# shellcheck disable=SC3043  # `local` is not POSIX but dash and busybox have it
set -eu

die() { printf 'prune-rs: %s\n' "$*" >&2; exit 1; }

cmd_list() {
  local ns="$1" keep="${2:-3}"
  [ -n "$ns" ] || die "list needs <namespace>"
  case "$keep" in ''|*[!0-9]*) die "keep must be a number, got '$keep'" ;; esac

  kubectl -n "$ns" get replicasets -o json 2>/dev/null | jq -r --argjson keep "$keep" '
    [ .items[]
      | select((.metadata.ownerReferences // []) | any(.kind == "Deployment"))
      | {
          name:     .metadata.name,
          owner:    ((.metadata.ownerReferences // [])[] | select(.kind=="Deployment") | .name),
          revision: ((.metadata.annotations["deployment.kubernetes.io/revision"] // "0") | tonumber),
          spec:     (.spec.replicas // 0),
          status:   (.status.replicas // 0),
          created:  .metadata.creationTimestamp
        }
    ]
    # Rank revisions per owning Deployment, newest first.
    | group_by(.owner)
    | map( sort_by(-.revision)
           | to_entries
           | map(.value + {rank: .key}) )
    | flatten
    | map(select(.spec == 0 and .status == 0 and .rank >= $keep))
    | sort_by(.owner, -.revision)
    | .[]
    | [.name, .owner, (.revision|tostring), .created] | @tsv'
}

cmd_prune() {
  local ns="$1" name="$2"
  [ -n "$ns" ] && [ -n "$name" ] || die "prune needs <namespace> <name>"

  # Re-check immediately before deleting. The list may be minutes old, and a
  # ReplicaSet can be scaled back up by a rollback in between — deleting it
  # then would kill running pods.
  local json spec status owner
  json="$(kubectl -n "$ns" get replicaset "$name" -o json 2>/dev/null)" \
    || die "no such ReplicaSet: $ns/$name"

  spec="$(printf '%s' "$json"   | jq -r '.spec.replicas // 0')"
  status="$(printf '%s' "$json" | jq -r '.status.replicas // 0')"
  owner="$(printf '%s' "$json"  | jq -r '[(.metadata.ownerReferences // [])[] | select(.kind=="Deployment") | .name] | first // ""')"

  [ "$spec" = "0" ]   || die "$ns/$name has spec.replicas=$spec — refusing (it is serving traffic)"
  [ "$status" = "0" ] || die "$ns/$name still has $status running pod(s) — refusing"
  [ -n "$owner" ]     || die "$ns/$name is not owned by a Deployment — refusing"

  kubectl -n "$ns" delete replicaset "$name" --wait=false >/dev/null \
    || die "delete failed for $ns/$name (is the zeroclaw-sre-prune RoleBinding applied to $ns?)"
  printf 'deleted %s/%s (deployment %s)\n' "$ns" "$name" "$owner"
}

case "${1:-}" in
  list)  shift; cmd_list  "${1:-}" "${2:-}" ;;
  prune) shift; cmd_prune "${1:-}" "${2:-}" ;;
  *)     die "usage: prune-rs.sh list <ns> [keep] | prune <ns> <name>" ;;
esac
