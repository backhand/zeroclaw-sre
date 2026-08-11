#!/bin/sh
# Which GitHub repo does a workload's issues belong in?
#
#   repo-map.sh resolve <namespace> <workload>   -> prints the repo, or nothing
#   repo-map.sh record  <namespace> <workload> <owner/repo>
#   repo-map.sh list
#
# Deterministic on purpose. Looking up "where do this workload's tickets go" is
# an exact-key question, and the answer decides where a public issue gets
# filed — so it is a script the SOP calls, not a judgement the model makes.
#
# Resolution order, first hit wins:
#
#   1. annotation on the workload      sre.zeroclaw/github-repo
#   2. annotation on its namespace     sre.zeroclaw/github-repo
#   3. exact entry in the ConfigMap    "<namespace>/<workload>"
#   4. namespace default in the map    "<namespace>/*"
#   5. $GH_REPO                        the cluster-wide fallback
#
# Annotations come first because they live with the workload, in whatever repo
# already owns its manifests — the mapping is reviewed with the deployment
# instead of accumulating as invisible agent state. The ConfigMap exists for
# workloads whose manifests you do not control.

# POSIX sh, not bash: the agent's risk profile allows `sh` and not `bash`, and
# the image's /bin/sh is dash — which has no `set -o pipefail`. Every pipeline
# here already tolerates its own failure (an empty result means "not recorded"),
# so pipefail would buy nothing anyway.
#
# shellcheck disable=SC3043  # `local` is not POSIX but dash and busybox both have it
set -eu

ANNOTATION="${REPO_MAP_ANNOTATION:-sre.zeroclaw/github-repo}"
CM_NAME="${REPO_MAP_CONFIGMAP:-zeroclaw-sre-repo-map}"
CM_NS="${REPO_MAP_NAMESPACE:-zeroclaw-sre}"
CM_KEY="map.json"

die() { printf 'repo-map: %s\n' "$*" >&2; exit 1; }

valid_repo() {
  # owner/repo, GitHub's own character rules. Rejects a URL, a shell
  # metacharacter, or an operator's typo before it reaches `gh issue create`.
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
}

# The whole mapping, as a JSON object. Missing ConfigMap or missing key is not
# an error: it just means nothing has been recorded yet.
read_map() {
  kubectl -n "$CM_NS" get configmap "$CM_NAME" -o json 2>/dev/null \
    | jq -r --arg k "$CM_KEY" '.data[$k] // empty' 2>/dev/null || true
}

# Read one annotation off any object. Both the annotation key and the ConfigMap
# key contain characters (`.`, `/`) that jsonpath treats as syntax, so every
# lookup here goes through jq instead of trying to escape them.
annotation_of() {   # annotation_of <kubectl get args...>
  kubectl "$@" -o json 2>/dev/null \
    | jq -r --arg a "$ANNOTATION" '.metadata.annotations[$a] // empty' 2>/dev/null || true
}

cmd_resolve() {
  local ns="$1" workload="$2"
  [ -n "$ns" ] && [ -n "$workload" ] || die "resolve needs <namespace> <workload>"

  # `workload` may arrive as "deployment/api" or bare "api".
  local kind name
  case "$workload" in
    */*) kind="${workload%%/*}"; name="${workload##*/}" ;;
    *)   kind="deployment";      name="$workload" ;;
  esac

  local found
  # 1. the workload's own annotation
  found="$(annotation_of -n "$ns" get "$kind" "$name")"
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi

  # 2. the namespace's annotation
  found="$(annotation_of get namespace "$ns")"
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi

  # 3 & 4. the mapping ConfigMap: exact entry, then namespace wildcard
  local map; map="$(read_map)"
  if [ -n "$map" ]; then
    found="$(printf '%s' "$map" | jq -r --arg k "$ns/$name" '.[$k] // empty' 2>/dev/null || true)"
    if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
    found="$(printf '%s' "$map" | jq -r --arg k "$ns/*" '.[$k] // empty' 2>/dev/null || true)"
    if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  fi

  # 5. the cluster-wide default, if the operator set one
  if [ -n "${GH_REPO:-}" ]; then printf '%s\n' "$GH_REPO"; return 0; fi

  # Nothing. The caller asks a human — that is not a failure.
  return 0
}

cmd_record() {
  local ns="$1" workload="$2" repo="$3"
  [ -n "$ns" ] && [ -n "$workload" ] && [ -n "$repo" ] \
    || die "record needs <namespace> <workload> <owner/repo>"
  valid_repo "$repo" || die "'$repo' is not an owner/repo — refusing to record it"

  local name="${workload##*/}"
  local map; map="$(read_map)"
  [ -n "$map" ] || map='{}'

  local updated
  updated="$(printf '%s' "$map" | jq -c --arg k "$ns/$name" --arg v "$repo" '.[$k] = $v')" \
    || die "the stored map is not valid JSON; fix it with: kubectl -n $CM_NS edit configmap $CM_NAME"

  # A merge patch on one key. file-ticket runs with max_concurrent = 1 and
  # admission_policy = "hold", so two recordings cannot race here.
  kubectl -n "$CM_NS" patch configmap "$CM_NAME" --type merge \
    -p "$(jq -n --arg k "$CM_KEY" --arg v "$updated" '{data: {($k): $v}}')" >/dev/null \
    || die "could not update $CM_NS/$CM_NAME — is the RoleBinding from deploy/repo-map.yaml applied?"

  printf 'recorded %s/%s -> %s\n' "$ns" "$name" "$repo"
}

cmd_list() {
  local map; map="$(read_map)"
  [ -n "$map" ] || { echo "(no mappings recorded)"; return 0; }
  printf '%s' "$map" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | sort
}

case "${1:-}" in
  resolve) shift; cmd_resolve "${1:-}" "${2:-}" ;;
  record)  shift; cmd_record  "${1:-}" "${2:-}" "${3:-}" ;;
  list)    cmd_list ;;
  *)       die "usage: repo-map.sh resolve <ns> <workload> | record <ns> <workload> <owner/repo> | list" ;;
esac
