# Build Spec: `zeroclaw-k3s-sre` — a purpose-built ZeroClaw distribution for k3s cluster operations

**Audience:** a coding agent implementing this repo end-to-end.
**Base:** ZeroClaw 0.7.x (`zeroclawlabs/zeroclaw:latest` image or lean source build).
**Canonical references:** https://docs.zeroclawlabs.ai · https://github.com/zeroclaw-labs/zeroclaw
When this spec and the current ZeroClaw docs disagree on config keys or CLI flags, follow the docs and note the deviation in `NOTES.md`.

---

## 1. Purpose

A single OCI image + Kubernetes manifests that deploy a supervised SRE agent into a k3s cluster. Out of the box it must:

1. Sweep the cluster on a schedule for unhealthy workloads (CrashLoopBackOff, ImagePullBackOff, OOMKilled, stuck Pending), pull the relevant logs/events, and post a digest to Slack and Discord.
2. Accept Alertmanager webhooks and investigate the referenced alert on demand.
3. Periodically compare actual resource usage to requests/limits and propose `kubectl patch` rightsizing changes, applying them **only after operator approval** in chat.
4. File GitHub issues for recurring/unresolved problems, with de-duplication.
5. Be operable entirely from Discord and Slack (questions, approvals, ad-hoc "why is X broken?").

All credentials arrive as **environment variables** (injected from a Kubernetes Secret). The image and the config in git contain no secrets.

## 2. Deliverables (repo layout)

```
zeroclaw-k3s-sre/
├── Dockerfile
├── entrypoint.sh
├── config/
│   └── config.toml.tmpl          # envsubst template → rendered at container start
├── workspace/                    # distro payload, synced into the live workspace on boot
│   ├── skills/
│   │   └── k3s-admin/
│   │       ├── SKILL.md
│   │       └── TEST.sh
│   └── sops/
│       ├── crashloop-sweep/      # SOP.toml + SOP.md
│       ├── alert-investigate/    # SOP.toml + SOP.md
│       ├── rightsize/            # SOP.toml + SOP.md
│       └── file-ticket/          # SOP.toml + SOP.md
├── deploy/
│   ├── namespace.yaml
│   ├── rbac.yaml                 # ServiceAccount + ClusterRole(s) + bindings
│   ├── secret.example.yaml       # documented placeholder values only
│   ├── pvc.yaml
│   ├── deployment.yaml
│   └── service.yaml              # cluster-internal, for Alertmanager → webhook
├── ci/
│   └── pipeline.yaml             # or Makefile targets equivalent
├── tests/
│   └── e2e/                      # k3d-based acceptance tests (Section 11)
├── README.md
└── NOTES.md                      # deviations, open questions, doc links used
```

## 3. Runtime architecture

```
Slack (Socket Mode) ◀──▶ ┐                       ┌─▶ shell tool: kubectl / gh / jq
Discord (gateway)  ◀──▶  ├─ zeroclaw daemon ─────┤   (autonomy: supervised)
Alertmanager ── POST ──▶ ┘   gateway :42617      └─▶ SQLite memory + receipts (PVC)
                              /sop/* , /health
```

- Slack uses **Socket Mode** and Discord uses its outbound gateway → no ingress needed for chat.
- The only in-cluster listener is the gateway Service, consumed by Alertmanager. Do not expose it outside the cluster.
- kubectl authenticates via the pod's ServiceAccount (in-cluster config). RBAC (Section 8) is the hard safety boundary; autonomy/skill rules are defense in depth.

## 4. Functional requirements

**FR1 — Scheduled health sweep.** SOP `crashloop-sweep`, cron trigger, default `*/15 * * * *` (interval configurable via env, baked into the rendered SOP or config — implementer's choice, document it). Behavior: enumerate non-Running/non-Succeeded pods across `ALLOWED_NAMESPACES` (default: all); for each finding, collect `kubectl describe`, recent events, and last ~50 lines of logs (`--previous` when restarting); post one digest message per sweep to both chat channels. A fully healthy sweep posts nothing (silence = healthy); a once-daily heartbeat summary confirms liveness.

**FR2 — Alert-driven investigation.** SOP `alert-investigate` with a webhook trigger at `/sop/alert-investigate`. Accepts Alertmanager's standard webhook JSON. The SOP extracts alertname/namespace/pod, investigates with the same toolkit as FR1, and posts findings to chat. Auth: gateway bearer plus `X-Webhook-Secret: $ZC_WEBHOOK_SECRET`; include an `X-Idempotency-Key` note in README for the Alertmanager config snippet you must provide.

**FR3 — Rightsizing with approval.** SOP `rightsize`, cron trigger, default weekly. Compare `kubectl top pods` (metrics-server ships with k3s — no Prometheus dependency) against configured requests/limits for workloads in `ALLOWED_NAMESPACES`. Produce a proposal table (workload, current, proposed, evidence). The apply step is a distinct SOP step with `requires_confirmation: true`; on approval, apply via `kubectl patch` of the workload's resource block only. Never scale replicas, never delete.

**FR4 — Ticket filing with dedupe.** SOP `file-ticket`, manual trigger, invoked from other SOPs/skill guidance when a finding (a) persists across ≥3 consecutive sweeps or (b) is explicitly escalated by an operator in chat. Compute a stable fingerprint (`namespace/workload/reason`), search open issues in `$GH_REPO` labeled `zeroclaw-sre` for the fingerprint, comment on an existing match instead of duplicating, otherwise `gh issue create` with logs excerpt, events, and first-seen/last-seen timestamps.

**FR5 — ChatOps.** Both channels support: free-form questions answered with live `kubectl` reads; approval prompts for medium-risk actions (Slack Block Kit buttons; Discord token-reply approvals); `sop_status` reporting on request. Restrict inbound to `allowed_*` lists driven by env (Section 5).

**FR6 — Env-only credentials.** No key, token, or secret may appear in the image, the git repo, or the rendered config's committed template defaults. See Section 5 for the resolution strategy per credential type.

**FR7 — Durable state.** SQLite memory, tool receipts, and SOP audit entries live under `/root/.zeroclaw` on a PVC and survive pod restarts and image upgrades.

## 5. Configuration

### 5.1 Credential strategy

- **LLM key:** rely on ZeroClaw's native env resolution — omit `api_key` from the provider block entirely; set `ANTHROPIC_API_KEY` (provider-specific env is step 3 in ZeroClaw's key-resolution order: inline → encrypted store → provider env → `ZEROCLAW_API_KEY` → `API_KEY`).
- **Channel tokens & other config-embedded secrets** (Discord bot token; Slack bot/app tokens + signing secret; webhook secret): ZeroClaw reads these from config fields, so `entrypoint.sh` renders `config.toml.tmpl` with `envsubst` into `$ZEROCLAW_CONFIG_DIR/config.toml` on an **emptyDir** (never the PVC, never the image layer) at startup. Fail fast with a clear message listing any missing required env var.
- **GitHub:** `GH_TOKEN` consumed natively by `gh`; pass through via `shell_env_passthrough`.
- Set `[secrets] backend = "none"` — the encrypted store is unused in this distro; document why in README.

### 5.2 Required / optional environment variables

| Var | Req | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes* | LLM provider (*or the key matching an overridden provider) |
| `DISCORD_BOT_TOKEN` | yes | Discord channel |
| `DISCORD_GUILD_ID` | yes | allowlisted guild |
| `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` / `SLACK_SIGNING_SECRET` | yes | Slack Socket Mode |
| `SLACK_CHANNEL_IDS` | yes | comma-separated digest/ops channels |
| `ZC_WEBHOOK_SECRET` | yes | Alertmanager → gateway auth |
| `GH_TOKEN` / `GH_REPO` | no | ticket filing (FR4 disabled with a logged warning if unset) |
| `ALLOWED_NAMESPACES` | no | comma-separated write scope; empty = all namespaces readable, writes require explicit list |
| `ZC_ALLOWED_USERS` | no | comma-separated operator IDs applied to both channels |
| `SWEEP_CRON`, `RIGHTSIZE_CRON` | no | override defaults from FR1/FR3 |

### 5.3 `config.toml.tmpl` — required content (sketch; verify keys against current docs)

```toml
[autonomy]
level = "supervised"
workspace_only = false
allowed_commands = ["kubectl", "gh", "jq", "sh", "curl"]
forbidden_commands = ["shutdown", "reboot", "mkfs", "rm"]
forbidden_paths = ["/etc", "/sys", "/boot", "/var/run/secrets"]
shell_env_passthrough = ["PATH", "HOME", "KUBERNETES_SERVICE_HOST",
  "KUBERNETES_SERVICE_PORT", "GH_TOKEN", "GH_REPO", "ALLOWED_NAMESPACES"]

[providers.models.claude]
kind = "anthropic"
model = "<current recommended Sonnet-class model>"   # no api_key line — env resolution

[channels.discord]
enabled = true
bot_token = "${DISCORD_BOT_TOKEN}"
allowed_guilds = ["${DISCORD_GUILD_ID}"]
reply_to_mentions_only = true

[channels.slack]
enabled = true
bot_token = "${SLACK_BOT_TOKEN}"
app_token = "${SLACK_APP_TOKEN}"
signing_secret = "${SLACK_SIGNING_SECRET}"
channel_ids = [${SLACK_CHANNEL_IDS_TOML}]   # entrypoint converts CSV → TOML list

[gateway]
host = "0.0.0.0"            # container networking; Service stays cluster-internal
allow_public_bind = true
port = 42617

[sop]
sops_dir = "sops"

[memory]
backend = "sqlite"

[secrets]
backend = "none"

[observability]
backend = "prometheus"       # /metrics for scraping; optional but include
```

Resolve during implementation (record in `NOTES.md`): exact non-interactive gateway auth for webhooks with `require_pairing` (token provisioning without an interactive pair step), Slack approval-button prerequisites, and whether `forbidden_paths` accepts the in-cluster token path as written (the intent: the *agent* must not read mounted SA secrets via file tools, while kubectl still authenticates normally — if both can't hold, drop that path entry and note it).

## 6. Workspace payload

### 6.1 `skills/k3s-admin/SKILL.md`

Frontmatter (`name`, `description`, `version`, `tags: [k8s, sre]`) plus instruction sections:

- **Identity & tone:** terse SRE colleague; every claim about cluster state must come from a command run this session, never from memory.
- **Hard rules:** never `delete`, `drain`, `cordon`, `scale`, or edit RBAC/secrets/webhooks; mutations limited to (a) resource requests/limits patches and (b) `kubectl rollout restart` — both only inside `ALLOWED_NAMESPACES` and only through the approval-gated SOP steps.
- **Diagnostic playbook:** the standard sequence (pods → describe → events → logs `--previous` → owner workload → recent rollout history) with exact kubectl invocations, jsonpath/field-selector snippets, and log-tail limits (≤50 lines per container into context).
- **Output contracts:** the digest format for sweeps (one line per finding: namespace/workload — reason — restarts — age — one-line log signature), the proposal table format for rightsizing, and the fingerprint definition for FR4.
- **Escalation ladder:** observed once → digest only; ≥3 sweeps → file ticket; operator asks → always answer with fresh data.

`TEST.sh`: static checks the skill can run offline (kubectl/gh/jq present, SKILL.md parses) so `zeroclaw skills test` is meaningful in CI.

### 6.2 SOPs

Each SOP ships `SOP.toml` (metadata + triggers per FR1–FR4; `execution_mode = "supervised"`; sensible `cooldown_secs`, `max_concurrent = 1`) and `SOP.md` (numbered steps, `- tools:` hints, `- requires_confirmation: true` on every mutating step). The rightsize apply step and any rollout-restart step are the only confirmation-gated steps; read-only steps must not prompt.

### 6.3 Workspace sync semantics

`entrypoint.sh` on every boot: copy `skills/` and `sops/` from the image's `/opt/distro/workspace/` into the live workspace, overwriting distro-owned files; never touch `*.db`, `receipts/`, or any path not shipped by the distro. This is the distro upgrade path — image tag bump = new skills/SOPs, state preserved (FR7).

## 7. Container image

- `FROM zeroclawlabs/zeroclaw:latest` (pin a digest at release time). A `--minimal`+features source build is a stretch goal, not required for v1.
- Add: `kubectl` (pin minor version; document skew policy vs k3s), `gh`, `jq`, `gettext` (envsubst), `ca-certificates`.
- Multi-arch: **linux/amd64 + linux/arm64** (k3s frequently runs on ARM).
- `ENTRYPOINT ["/entrypoint.sh"]` → validate env → render config → sync workspace → exec the daemon.
- Image must pass a secret scan (e.g. gitleaks) and contain no writable state paths outside `/root/.zeroclaw`, `/tmp`, `$ZEROCLAW_CONFIG_DIR`.

## 8. Kubernetes manifests (`deploy/`)

- **Namespace** `zeroclaw-sre`.
- **RBAC:**
  - ClusterRole `zeroclaw-sre-read`: `get/list/watch` on pods, `pods/log`, events, nodes, namespaces, deployments, replicasets, statefulsets, daemonsets, jobs, cronjobs; `get/list` on `metrics.k8s.io` pods+nodes. **No** verbs on secrets.
  - ClusterRole `zeroclaw-sre-write`: `patch` on deployments/statefulsets/daemonsets only. Bind it namespaced (RoleBindings generated for `ALLOWED_NAMESPACES`) — provide a documented, off-by-default variant for cluster-wide binding.
- **Deployment:** 1 replica, `Recreate` strategy (SQLite). Hardened context: `runAsNonRoot`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, drop ALL caps, `seccompProfile: RuntimeDefault`. Mounts: PVC → `/root/.zeroclaw`; emptyDirs → `/tmp`, `$ZEROCLAW_CONFIG_DIR`. Env from the Secret. Probes: readiness+liveness `GET /health :42617`. Resources: requests `100m/128Mi`, limits `500m/512Mi`.
- **Service:** ClusterIP :42617 with a README snippet for the Alertmanager receiver (URL, bearer, `X-Webhook-Secret`).
- **PVC:** 1Gi, default StorageClass (k3s local-path works).
- Sandbox backend: attempt `landlock`, fall back to `none` with a logged warning; **never** the docker backend in-cluster. Record observed behavior under RuntimeDefault seccomp in `NOTES.md`.

## 9. Security requirements (summary of the layered model)

RBAC is authoritative (no delete verbs exist to misuse) → autonomy `supervised` gates medium-risk shell in chat → SOP `requires_confirmation` gates the specific mutating steps → skill hard rules steer the model → receipts + SOP audit log make everything reviewable. A finding that any single layer's failure enables an unapproved mutation is a release blocker.

## 10. CI pipeline

1. Lint/static: shellcheck on scripts, `envsubst` dry-run with dummy env, gitleaks.
2. In a container from the built image: `zeroclaw doctor`, `zeroclaw skills audit k3s-admin`, `zeroclaw skills test k3s-admin`, `zeroclaw sop validate` — all must pass.
3. Build & push multi-arch image, tag `vX.Y.Z` + digest pin in `deploy/deployment.yaml`.
4. e2e job (Section 11) on k3d, amd64 at minimum.

## 11. Acceptance tests (k3d, scriptable)

1. **Boot:** deploy with test env; pod Ready; `/health` OK; no secret material in `kubectl get pod -o yaml` beyond Secret refs; rendered config absent from the PVC.
2. **Sweep detects:** create a deployment with a bad image; within one sweep interval both a Slack and a Discord message name the workload with reason + log/event evidence. (Mock/webhook-stub the chat APIs if live tokens aren't available in CI; assert on outbound payloads.)
3. **Quiet when healthy:** delete the broken deployment; next sweep produces no digest.
4. **Alert path:** POST a sample Alertmanager payload with correct secret → investigation message; with a wrong secret → rejected, no LLM invocation.
5. **Approval gate:** run rightsize against an over-provisioned test workload; verify a proposal is posted and **no patch occurs**; approve; verify the patch applied and matches the proposal; verify a receipt + SOP audit entry exist.
6. **Ticket dedupe:** force the same finding across 3 sweeps → exactly one issue in the test repo; a 4th sweep comments instead of opening a second.
7. **RBAC negative:** from inside the pod, `kubectl delete pod ...` and `kubectl get secret ...` both fail with authorization errors.
8. **Persistence:** delete the pod; after restart the agent still knows prior findings (fingerprint state) and receipts are intact.

## 12. Out of scope (v1)

Prometheus/Grafana integration beyond the optional `/metrics` endpoint; auto-apply without approval; multi-cluster; Jira (GitHub only); local-LLM bundling; horizontal scaling of the agent.

## 13. README must cover

Prereqs (k3s, chat app setup for both platforms with required scopes/intents), Secret creation from env vars, install/upgrade/rollback (image tag bump semantics from 6.3), the Alertmanager snippet, how approvals look in each channel, and how to read receipts/SOP audit entries.
