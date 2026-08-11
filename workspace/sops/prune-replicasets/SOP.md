# prune-replicasets

Housekeeping. The only procedure in this distribution that deletes anything,
and the only one whose RBAC includes a destructive verb — so the candidate list
is computed by a script, shown in full, and deleted one object at a time.

Steps 1–2 are read-only. Step 4 deletes, and cannot run without approval.

## Steps

1. **Scope** — Read `$ALLOWED_NAMESPACES`. Empty means nothing is prunable: say so and stop. A namespace without the `zeroclaw-sre-prune` RoleBinding will refuse the delete even if it is listed, which is intentional — report that plainly if it happens rather than retrying.
   - tools: shell

2. **List candidates** — For each namespace in scope run `sh "$ZC_WORKSPACE_DIR/skills/k3s-admin/bin/prune-rs.sh" list <namespace> <keep>`, with `keep` defaulting to 3. It returns only ReplicaSets that are owned by a Deployment, scaled to zero, with no pods still terminating, and outside the newest `keep` revisions. Do not add candidates of your own and do not lower `keep` because the list looks short.
   - tools: shell

3. **Show the work** — Post one message: the count per namespace, then one line per candidate as `namespace/name — deployment — revision — age`. Say explicitly how many revisions are being kept and that rollback beyond that point will no longer be possible. If there are no candidates, say so in one line and stop.
   - tools: send_via

4. **Approval gate** — Wait for an operator to approve. Silence is not approval. If they name a subset, prune only that subset.
   - kind: checkpoint
   - requires_confirmation: true

5. **Prune** — For each approved candidate call the `k8s__prune_replicaset` tool with its namespace and name. One call per ReplicaSet. The tool re-reads the object and refuses anything that is no longer scaled to zero, because a rollback between step 2 and here would have made it live again. Never use `kubectl delete` and never use `prune-rs.sh prune` — both bypass the approval this tool carries. Stop on the first refusal and report it verbatim; do not work around it.
   - tools: k8s__prune_replicaset
   - requires_confirmation: true

6. **Confirm** — Post one line with the number deleted per namespace and any that were refused, with the reason given.
   - tools: send_via
