# rightsize

Propose resource requests/limits that match observed usage. Steps 1–4 are
read-only. Step 6 is the only step in this distribution that changes cluster
state, and it cannot run without an operator approving the exact proposal from
step 4.

## Steps

1. **Scope** — Read `$ALLOWED_NAMESPACES`. If it is empty there is no writable namespace: say so, produce the proposal anyway as information, and stop before step 5. Otherwise enumerate Deployments, StatefulSets and DaemonSets in those namespaces.
   - tools: shell

2. **Measure** — `kubectl top pods -n <ns> --containers` for each namespace in scope. If metrics-server is unavailable, report that and stop — never estimate usage. Take the highest observed value per container as the peak, and use the memory of previous runs (`rightsize:<workload>` keys) to build a p95 rather than judging on one sample.
   - tools: shell, memory_recall

3. **Compare** — For each container, read the configured requests and limits. Flag a container when its request exceeds p95 by more than 20%, when its limit is below observed peak, or when it has no requests set at all.
   - tools: shell

4. **Propose** — Build the proposal table in the skill's format: never below p95 for a request, never below peak for a limit, round CPU up to 50m and memory up to 64Mi, skip anything moving less than 20%. Post it to Slack, then send the identical table to Discord with `send_via(target: "discord.ops", body: <table>)`. State explicitly that nothing has been changed.
   - tools: send_via, memory_store

5. **Approval gate** — Wait for an operator to approve the proposal. Do not proceed on silence, on a thumbs-up from a non-operator, or on your own judgement. If the operator names a subset of workloads, carry only that subset into step 6.
   - kind: checkpoint
   - requires_confirmation: true

6. **Apply** — For each approved workload, patch the resources block only:
   `kubectl patch <kind>/<name> -n <ns> --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"<c>","resources":{"requests":{...},"limits":{...}}}]}}}}'`.
   One patch per workload. Never scale, never delete, never touch image, probes or replicas. Verify each patch by re-reading the workload's resources and post a one-line confirmation per workload naming the applied values.
   - tools: shell
   - requires_confirmation: true

7. **Record** — Store the applied values under `rightsize:<workload>` with a timestamp so the next run compares against the new baseline rather than re-proposing the same change.
   - tools: memory_store
