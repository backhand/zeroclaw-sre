# zeroclaw-k3s-sre

A supervised SRE agent for a k3s/k8s cluster: one OCI image plus manifests.

It sweeps the cluster on a schedule, posts a digest of what is broken to Slack
and Discord, investigates Alertmanager alerts on demand, proposes rightsizing
changes and applies them **only after you approve in chat**, and files
de-duplicated GitHub issues for problems that will not go away.

It is deliberately hard to make it do damage. The ServiceAccount has no
destructive verb and no access to secrets, so the strongest possible prompt
injection still cannot delete a pod.

Built on [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) 0.8.4. Where the
build spec and the shipped runtime disagree, [NOTES.md](NOTES.md) records the
deviation and the evidence.

---

## What it does

| | |
|---|---|
| **Scheduled sweep** | Every 15 min by default: finds non-Running pods *and* Running-but-crash-looping ones, pulls describe + events + ≤50 log lines, posts one digest to both chat channels. A healthy sweep posts **nothing** — silence is the signal, and a daily heartbeat proves it is alive. |
| **Alert investigation** | Alertmanager POSTs to a cluster-internal endpoint; the agent checks the alert against live cluster state and reports whether it is real, stale or resolved. |
| **Rightsizing** | Weekly: compares `kubectl top` against configured requests/limits, posts a proposal table, and waits. Applies `kubectl patch` of the resources block only, after approval, in allowed namespaces only. |
| **Ticketing** | A finding seen in three consecutive sweeps becomes one GitHub issue, in the repo that owns that workload. Later sweeps comment on it; they never open a second. When it does not know the repo, it asks in chat once and remembers the answer. |
| **ChatOps** | Ask "why is prod/api broken?" in Slack or Discord and get an answer from commands run right then, never from memory. |

---

## Prerequisites

- **k3s or any Kubernetes 1.35–1.37** (kubectl in the image is pinned to
  v1.36.3; see [NOTES.md §10](NOTES.md)). `metrics-server` must be running —
  it ships with k3s by default and rightsizing depends on it.
- **A default StorageClass.** k3s's `local-path` is fine.
- **An LLM API key.** Anthropic by default; any provider family ZeroClaw
  supports works — set `ZC_PROVIDER_FAMILY` and `ZC_MODEL` in the ConfigMap
  (e.g. `xai` + `grok-4.5`).
- **A Discord bot** and/or **a Slack app** (below). Either one is enough;
  configure both if you want the digest in both places.

  > **Slack needs a source build.** No published ZeroClaw image compiles the
  > Slack channel — the binary reports `🚫 Slack (configured, not compiled)`.
  > Build with `docker build --build-arg ZC_SLACK=1 .` (a full Rust build:
  > ~2 GB RAM, tens of minutes). Discord works on the default image.
  > See [NOTES.md §14](NOTES.md).
- Optional: a **GitHub token** for ticket filing, and **Alertmanager** for the
  alert path.

### Slack app

1. Create an app at <https://api.slack.com/apps> → *From scratch*.
2. **Socket Mode** → enable. Generate an app-level token with
   **`connections:write`** → this is `SLACK_APP_TOKEN` (`xapp-…`). That is the
   only app-level scope, and it is not a bot scope.
3. **OAuth & Permissions** → **bot token scopes**. The required set, and what
   each one is actually for:

   | Scope | Needed for |
   |---|---|
   | `chat:write` | posting digests, proposals and answers (`chat.postMessage`, `chat.update`) |
   | `app_mentions:read` | receiving `@zeroclaw why is prod/api broken?` |
   | `channels:history` | reading the thread an approval reply lands in |
   | `channels:read` | resolving the channel IDs in `SLACK_CHANNEL_IDS` |
   | `users:read` | mapping a sender to an operator ID before honouring an approval |

   Add only if they apply to you:

   | Scope | Needed for |
   |---|---|
   | `groups:history`, `groups:read` | the ops channel is **private** |
   | `im:history`, `im:read`, `mpim:history`, `mpim:read` | ChatOps in DMs / group DMs |
   | `reactions:read`, `reactions:write` | only if you set `cancel_reaction` on the channel |
   | `files:read`, `files:write` | file uploads — this distribution never uploads files |

   Install to the workspace → `SLACK_BOT_TOKEN` (`xoxb-…`).
4. **Event Subscriptions** → subscribe to bot events: **`app_mention`** and
   **`message.channels`** (plus `message.groups` for a private channel).

   `message.channels` is not optional even though the bot is configured with
   `mention_only = true`. Approvals are replies in a thread and people do not
   @-mention the bot to say "approve"; the runtime lets un-mentioned *thread*
   replies through precisely so that works, but it can only do that if Slack
   delivers the message event at all.
5. Invite the bot to your ops channel and copy the channel ID (`C…`) →
   `SLACK_CHANNEL_IDS`.
6. No signing secret is needed — Socket Mode authenticates with the app token,
   and 0.8.x has no `signing_secret` field to put one in.

### Discord bot

1. Create an application at <https://discord.com/developers/applications>, add
   a **Bot** → token is `DISCORD_BOT_TOKEN`.
2. **Privileged Gateway Intents** → enable **Message Content** and **Server
   Members**.
3. Invite it with *Send Messages*, *Read Message History* and *View Channel*.
4. Copy the server (guild) ID → `DISCORD_GUILD_ID`, and the ops channel ID →
   `DISCORD_CHANNEL_IDS`. (Developer Mode → right-click → Copy ID.)

### Operator IDs

Set `ZC_ALLOWED_USERS` to the user IDs allowed to approve mutations — Slack
`U…` IDs and/or Discord user IDs. **If this is empty, nobody can approve a
rightsizing patch**, and the agent will say so at startup.

---

## Install

```bash
git clone git@github.com:backhand/zeroclaw-sre.git
cd zeroclaw-sre
```

### 1. Namespace and RBAC

```bash
kubectl apply -f deploy/namespace.yaml
kubectl apply -f deploy/rbac.yaml
kubectl apply -f deploy/repo-map.yaml
```

`deploy/rbac.yaml` grants cluster-wide **read and nothing else**. No write
binding ships with it, on purpose. Grant write per namespace when you want it:

```bash
make rolebindings ALLOWED_NAMESPACES=prod,staging | kubectl apply -f -
```

A namespace with no RoleBinding is read-only to the agent no matter what
`ALLOWED_NAMESPACES` says. The env var narrows intent; RBAC decides what is
possible.

### 2. Create the Secret

Never commit a filled-in `deploy/secret.example.yaml`. Build it from your
environment:

```bash
kubectl -n zeroclaw-sre create secret generic zeroclaw-sre \
  --from-literal=LLM_API_KEY="$LLM_API_KEY" \
  --from-literal=SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" \
  --from-literal=SLACK_APP_TOKEN="$SLACK_APP_TOKEN" \
  --from-literal=DISCORD_BOT_TOKEN="$DISCORD_BOT_TOKEN" \
  --from-literal=ZC_WEBHOOK_SECRET="$(openssl rand -hex 32)" \
  --from-literal=ZC_GATEWAY_TOKEN="$(openssl rand -hex 32)" \
  --from-literal=GH_TOKEN="${GH_TOKEN:-}"
```

`ZC_WEBHOOK_SECRET` is what Alertmanager must present. `ZC_GATEWAY_TOKEN` is
the pre-seeded gateway bearer, so nothing needs an interactive pairing step.
Both are pod-internal; generate them once and keep them in your secret store.

### 3. Which repo do tickets go to?

One cluster runs many teams' deployments, so this is per-workload. The agent
resolves it in order — first hit wins:

1. `sre.zeroclaw/github-repo` annotation on the workload
2. the same annotation on its namespace
3. an exact entry in the `zeroclaw-sre-repo-map` ConfigMap
4. a `namespace/*` wildcard in that ConfigMap
5. `GH_REPO`, the cluster-wide fallback

Annotate the workload if you own its manifests — the mapping then lives in the
repo it points at and gets reviewed with the deployment:

```yaml
metadata:
  annotations:
    sre.zeroclaw/github-repo: acme/api-gateway
```

For anything else, `kubectl apply -f deploy/repo-map.yaml` and either fill the
map in yourself or let the agent ask. **When nothing resolves, it asks in chat
which repo to use and records the answer**, so each deployment is asked about
exactly once. Inspect or correct it any time:

```bash
kubectl -n zeroclaw-sre get cm zeroclaw-sre-repo-map -o jsonpath='{.data.map\.json}' | jq .
```

The agent's RBAC grants `get`/`patch` on that one ConfigMap by name and no
other — it still cannot read configmaps anywhere else in the cluster.

### 4. Configure

Edit `deploy/configmap.yaml` — channel IDs, `ALLOWED_NAMESPACES`, the cron
schedules, `GH_REPO`. Everything in it is non-secret by construction.

### 5. Deploy

```bash
make deploy
```

or apply `deploy/{configmap,pvc,service,deployment}.yaml` yourself. Then:

```bash
kubectl -n zeroclaw-sre logs -f deploy/zeroclaw-sre -c zeroclaw
```

A healthy start renders the config, syncs the workspace payload, warns about
anything optional you left out, and reports `starting zeroclaw daemon`.

---

## Wiring Alertmanager

The Service publishes one port: `9099`, the alert adapter. Point a receiver at
it. Alertmanager ≥ 0.27:

```yaml
receivers:
  - name: zeroclaw-sre
    webhook_configs:
      - url: http://zeroclaw-sre.zeroclaw-sre.svc.cluster.local:9099/alerts
        send_resolved: true
        max_alerts: 20
        http_config:
          http_headers:
            X-Webhook-Secret:
              secret_files:
                - /etc/alertmanager/secrets/zc-webhook-secret

route:
  receiver: zeroclaw-sre
  group_by: [alertname, namespace]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
```

Older Alertmanager cannot set custom headers; send the same secret as a bearer
credential instead:

```yaml
        http_config:
          authorization:
            type: Bearer
            credentials_file: /etc/alertmanager/secrets/zc-webhook-secret
```

Mount the secret into Alertmanager however your stack does it — with the
Prometheus Operator, add `zeroclaw-sre` to the Alertmanager CR's `secrets:`
list and the file appears at
`/etc/alertmanager/secrets/zeroclaw-sre/ZC_WEBHOOK_SECRET`.

**Idempotency.** The adapter derives an `X-Idempotency-Key` from the alert
group's own identity (`groupKey` + per-alert fingerprints + status), so
Alertmanager's `repeat_interval` re-sends collapse instead of re-investigating.
The window is 15 minutes (`gateway.idempotency_ttl_secs`). If you want the
sender to control it instead, set your own `X-Idempotency-Key` upstream.

Verify the wiring without waiting for a real alert:

```bash
kubectl -n zeroclaw-sre exec deploy/zeroclaw-sre -c alert-adapter -- \
  wget -qO- --header='Content-Type: application/json' \
    --header="X-Webhook-Secret: $ZC_WEBHOOK_SECRET" \
    --post-file=tests/e2e/fixtures/alert-firing.json \
    http://127.0.0.1:9099/alerts
```

A wrong secret returns `401` and never reaches the model.

---

## How approvals look

Read-only work never prompts. Two things prompt: the rightsize **apply** step,
and any rollout restart.

**Slack.** The agent posts the proposal table, then a request to approve. Reply
in the thread — the runtime renders its own approval control, and a plain
`approve` / `deny` in the thread also resolves it. Only IDs in
`ZC_ALLOWED_USERS` count.

**Discord.** The approval request carries a short token. Reply with:

```
<token> approve
<token> deny
```

**Out of band**, when chat is not an option:

```bash
kubectl -n zeroclaw-sre exec deploy/zeroclaw-sre -c zeroclaw -- zeroclaw sop pending
kubectl -n zeroclaw-sre exec deploy/zeroclaw-sre -c zeroclaw -- zeroclaw sop approve <run-id>
kubectl -n zeroclaw-sre exec deploy/zeroclaw-sre -c zeroclaw -- zeroclaw sop deny <run-id>
```

An unanswered approval expires after 30 minutes and is treated as a denial —
it never applies on timeout.

---

## Reading the audit trail

Three independent records, in increasing order of trust:

**1. Tool receipts** — one HMAC-signed line per tool call, including calls that
were blocked or denied. Append-only, day-sharded:

```bash
make receipts
# or
kubectl -n zeroclaw-sre exec deploy/zeroclaw-sre -c zeroclaw -- \
  sh -c 'tail -n 50 /data/workspace/receipts/$(date -u +%Y-%m-%d).ndjson'
```

The signing key is generated per daemon process and never written to disk, so
the model cannot fabricate a receipt for a command it did not run. Receipts do
not survive a restart as *verifiable* records — the key rotates — but the lines
themselves persist on the PVC.

**2. SOP audit entries** — one per run, per step and per approval:

```bash
kubectl -n zeroclaw-sre exec deploy/zeroclaw-sre -c zeroclaw -- \
  zeroclaw memory list --category sop --limit 20
```

Keys are `sop_run_<id>`, `sop_step_<id>_<n>`, `sop_approval_<id>_<n>`.

**3. Cluster-side.** The agent's identity is
`system:serviceaccount:zeroclaw-sre:zeroclaw-sre`; every mutation it makes is
in the API server audit log under that name, whatever the agent later says
about it.

---

## Upgrading

The image tag is the unit of upgrade. Skills and SOPs are baked into the image
and re-synced into the workspace on every boot, so bumping the tag changes the
agent's behaviour while the PVC keeps memory, receipts, fingerprint counters
and SOP history.

```bash
kubectl -n zeroclaw-sre set image deploy/zeroclaw-sre \
  zeroclaw=ghcr.io/backhand/zeroclaw-sre:v0.2.0 \
  alert-adapter=ghcr.io/backhand/zeroclaw-sre:v0.2.0
kubectl -n zeroclaw-sre rollout status deploy/zeroclaw-sre
```

**Rollback** is the same command with the previous tag. State is
forward-and-backward compatible because the distro never writes into the
directories it replaces (`skills/`, `sops/`) and never touches the ones it
does not own (`*.db`, `receipts/`, `state/`).

Prefer digests over tags in production — `make release` pins the digest into
`deploy/deployment.yaml` automatically.

The deployment strategy is `Recreate` on purpose: SQLite is single-writer and
the PVC is ReadWriteOnce. Do not change it to RollingUpdate.

---

## Development

Images are built by CI, not locally — `amd64` under emulation on an arm64
machine is slow, and the Slack variant's Rust build is impractical that way.
Run the **release** workflow from the Actions tab: give it a tag (`test` for a
scratch build), pick `default`, `slack` or `both`, and it builds each
architecture on a native runner. Pushing a `v*.*.*` tag does the same thing and
pins the digest into `deploy/deployment.yaml`.

```bash
make help          # every target
make lint          # shellcheck, YAML, go vet/test, envsubst dry-run, gitleaks
make build         # build the image for this host
make image-test    # render config + sop validate + skills audit/test, in-image
make image-scan    # no writable state paths outside /data and /tmp
make e2e           # k3d acceptance suite (needs k3d)
```

`make e2e` runs everything it can without credentials and **skips** — never
fakes — the cases that need a real model call. Supply `ANTHROPIC_API_KEY` (and
`GH_TOKEN` + `E2E_GH_REPO` for the ticket-dedupe case) to run the full set.
`KEEP_CLUSTER=1` leaves the cluster up for debugging.

---

## Layout

```
Dockerfile              multi-arch image: ZeroClaw + kubectl + gh + jq + envsubst
entrypoint.sh           validate env -> render config -> sync workspace -> exec daemon
config/config.toml.tmpl the config, with non-secret placeholders only
alert-adapter/          Alertmanager -> gateway bridge (Go, unit-tested)
workspace/
  skills/k3s-admin/     the diagnostic playbook, output contracts and hard rules
  sops/                 crashloop-sweep, alert-investigate, rightsize, file-ticket
deploy/                 namespace, RBAC, ConfigMap, Secret example, PVC, Deployment, Service, NetworkPolicy
tests/e2e/              k3d acceptance suite (spec §11)
NOTES.md                every deviation from the build spec, with evidence
```

---

## Security model

Five layers, outermost first. Only the first one is not talk:

1. **RBAC** — no `delete`, no `create`, no `update`, no access to secrets or
   configmaps, anywhere. `patch` on workloads only, only in namespaces you
   bound. This holds regardless of what the model decides to do.
2. **Autonomy `supervised`** — medium-risk shell asks in chat; high-risk is
   blocked. A strict `allowed_commands` list means anything not named is
   refused outright.
3. **SOP confirmation gates** — the rightsize apply step (and any rollout
   restart) cannot run without an explicit approval from a listed operator.
4. **Skill hard rules** — the model is told, in detail, what it must never do.
5. **Receipts + SOP audit + API-server audit** — everything that happened is
   reviewable afterwards from three independent places.

If you find a path where any single layer failing produces an unapproved
mutation, that is a release blocker, not a bug report.

The container adds: non-root (65534), read-only root filesystem, all
capabilities dropped, no privilege escalation, `seccompProfile: RuntimeDefault`,
and a namespace enforcing the `restricted` Pod Security Standard. The OS-level
sandbox is deliberately **off** — see [NOTES.md §6](NOTES.md) for why turning
it on breaks in-cluster authentication outright.

No credential is ever written to the image, to git, or to any file on the PVC:
every secret is injected as an in-memory config override. See
[NOTES.md §2](NOTES.md).
