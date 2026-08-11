#!/bin/sh
# Feed one canned `kubectl get pods -o json` fixture through the skill's jq
# program. Used by TEST.sh, which cannot contain shell pipes itself (its parser
# splits lines on " | ").
#
#   sh tests/jq-fixture.sh crashloop|oomkilled|healthy|pending

set -eu

case "${1:-}" in
  crashloop)
    fixture='{"items":[{"metadata":{"namespace":"prod","name":"api-1"},
      "status":{"phase":"Running","startTime":"2026-08-11T06:00:00Z",
        "containerStatuses":[{"ready":false,"restartCount":47,
          "state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}'
    ;;
  oomkilled)
    fixture='{"items":[{"metadata":{"namespace":"stg","name":"etl-9"},
      "status":{"phase":"Running","startTime":"2026-08-10T00:00:00Z",
        "containerStatuses":[{"ready":true,"restartCount":8,
          "state":{"running":{}},
          "lastState":{"terminated":{"reason":"OOMKilled","exitCode":137}}}]}}]}'
    ;;
  pending)
    fixture='{"items":[{"metadata":{"namespace":"s","name":"pend-1"},
      "status":{"phase":"Pending","startTime":"2026-08-11T06:00:00Z"}}]}'
    ;;
  healthy)
    fixture='{"items":[{"metadata":{"namespace":"x","name":"ok-1"},
      "status":{"phase":"Running","startTime":"2026-08-01T00:00:00Z",
        "containerStatuses":[{"ready":true,"restartCount":0,
          "state":{"running":{}}}]}}]}'
    ;;
  *)
    echo "usage: $0 crashloop|oomkilled|healthy|pending" >&2
    exit 2
    ;;
esac

printf '%s' "$fixture" | jq -r -f "$(dirname "$0")/../jq/unhealthy-pods.jq"
