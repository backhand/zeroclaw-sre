# release

Move a workload to a new image tag, or restart it in place, and stay until the
rollout finishes.

Steps 1–3 are read-only. Step 5 changes the cluster and cannot run without
approval. A rollout is not finished when the command returns — step 6 is what
makes this different from typing `kubectl set image` yourself.

## Steps

1. **Scope and target** — The workload must be in `$ALLOWED_NAMESPACES`; if it is not, say so and stop. Resolve the exact object (`deployment/<name>`) and confirm it exists. Never guess which workload was meant from a partial name — ask.
   - tools: shell

2. **Record the current state** — Capture the current image per container, replica count, and current revision (`kubectl rollout history`). This is what a rollback returns to, so it goes in the proposal and in the final message.
   - tools: shell

3. **Check the new tag exists** — For an image change, verify the target tag is actually pullable before proposing it: `kubectl run` is forbidden, so check the registry with `curl`/`gh` or state plainly that you could not verify. A rollout to a nonexistent tag is an ImagePullBackOff you caused.
   - tools: shell

4. **Propose** — Post one message: workload, container, current image → proposed image (or "restart, no image change"), current revision, and the exact `kubectl` command you intend to run. Nothing has changed yet; say so.
   - tools: send_via

5. **Approval gate, then apply** — Wait for approval, then run exactly the command that was approved:
   - image change: `kubectl set image deployment/<name> <container>=<image> -n <ns>`
   - restart only: `kubectl rollout restart deployment/<name> -n <ns>`
   Both are patches, which is all the RBAC allows. Never scale, never delete, never edit anything outside the container image and the restart annotation.
   - kind: checkpoint
   - requires_confirmation: true
   - tools: shell

6. **Watch it land** — `kubectl rollout status deployment/<name> -n <ns> --timeout=300s`. If it succeeds, post the new revision and the observed image. If it fails or times out, immediately run the diagnostic playbook against the new pods, post what is actually wrong, and offer `kubectl rollout undo deployment/<name> -n <ns>` — as a proposal requiring its own approval, not something you do unprompted.
   - tools: shell, send_via

7. **Record** — Store `release:<namespace>/<workload>` in memory with the previous image, the new image, the revision, and who approved, so the next sweep can correlate a new finding with a recent rollout.
   - tools: memory_store
