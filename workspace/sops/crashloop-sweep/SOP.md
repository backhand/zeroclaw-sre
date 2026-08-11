# crashloop-sweep

Scheduled health sweep. Read-only from end to end: no step in this procedure
mutates the cluster, so no step asks for confirmation.

Follow the `k3s-admin` skill for every command, every format, and every rule.

## Steps

1. **Enumerate** — List every pod that is not Running/Succeeded across the cluster, plus every Running pod with a not-ready or waiting container. Use both enumeration commands from the skill's playbook step 1; the field-selector alone misses crash-looping pods that report Running.
   - tools: shell

2. **Collect evidence** — For each unhealthy pod: describe it, read its namespace events, and pull at most 50 log lines (`--previous` first when it is restarting). Resolve each pod to its owning workload so several bad pods of one Deployment collapse into one finding. Skip pods younger than 60s — they are still starting.
   - tools: shell

3. **Fingerprint and count** — Compute `<namespace>/<workload>/<reason>` for each finding. Recall `sweep:<fingerprint>` from memory; increment its consecutive-sweep counter and update last-seen. Reset to zero and note recovery for any stored fingerprint absent from this sweep.
   - tools: memory_recall, memory_store

4. **Post the digest** — If there are zero findings, post nothing and reply exactly `SWEEP_CLEAN`; stop here. Otherwise build one digest in the skill's format and post it to Slack (this run's delivery channel), then send the identical text to Discord with `send_via(target: "discord.ops", body: <digest>)`.
   - tools: send_via

5. **Escalate what persists** — For every finding whose consecutive-sweep counter has reached 3 and that has no issue URL stored, run the `file-ticket` SOP with that fingerprint. Findings below 3, or already ticketed with unchanged evidence, are digest-only.
   - tools: sop_execute
