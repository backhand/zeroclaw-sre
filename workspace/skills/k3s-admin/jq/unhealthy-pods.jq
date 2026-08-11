# Emit one TSV row per unhealthy pod from `kubectl get pods -o json`.
#
#   namespace <TAB> pod <TAB> reason <TAB> restarts <TAB> startTime
#
# Catches what `--field-selector status.phase!=Running` misses: pods that are
# Running but whose containers are crash-looping, not ready, or were OOMKilled.
#
#   kubectl get pods --all-namespaces -o json \
#     | jq -r -f "$ZC_WORKSPACE_DIR/skills/k3s-admin/jq/unhealthy-pods.jq"

(.items // [])[]
| . as $pod
| ((.status.containerStatuses // []) + (.status.initContainerStatuses // [])) as $cs
| select(
    ($pod.status.phase != "Running" and $pod.status.phase != "Succeeded")
    or ($cs | any(.ready == false))
    or ($cs | any((.state.waiting.reason // "") != ""))
    or ($cs | any((.lastState.terminated.reason // "") == "OOMKilled"))
  )
| (($cs
     | map(.state.waiting.reason // .lastState.terminated.reason // empty)
     | first)
   // $pod.status.reason
   // $pod.status.phase
   // "Unknown") as $reason
| (($cs | map(.restartCount // 0) | add) // 0) as $restarts
| [ $pod.metadata.namespace,
    $pod.metadata.name,
    $reason,
    ($restarts | tostring),
    ($pod.status.startTime // "unknown")
  ]
| @tsv
