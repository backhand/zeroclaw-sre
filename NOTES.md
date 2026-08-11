# NOTES — deviations, evidence, open questions

The build spec (`zeroclaw-k3s-sre-spec.md`) targets ZeroClaw 0.7.x and says:

> When this spec and the current ZeroClaw docs disagree on config keys or CLI
> flags, follow the docs and note the deviation in `NOTES.md`.

They disagree in several places, and in a few the *docs* disagree with the
shipped code. Everything below was verified against the real artifacts, not
inferred:

- **the released binary** — `ghcr.io/zeroclaw-labs/zeroclaw:debian`, ZeroClaw
  **0.8.4**, run locally (`zeroclaw config schema`, `config list`, `sop
  validate`, `skills audit/test`, `doctor`);
- **the source at the release tags** — `github.com/zeroclaw-labs/zeroclaw`
  at `v0.7.5` and `v0.8.4`;
- **the versioned docs** — `docs.zeroclawlabs.ai/v0.8.4/en/`.

File/line references below point into the upstream repo at `v0.8.4`.

---

## 0. Target version: 0.8.4, not 0.7.x

**Spec:** "Base: ZeroClaw 0.7.x".

**What shipped:** the current stable line is 0.8.x (0.8.4 at the time of
writing), and `docs.zeroclawlabs.ai` redirects to `/v0.8.4/en/` — there is no
published 0.7.5 documentation left to follow. 0.8 also restructured the config
schema (`schema_version = 3`): providers became
`[providers.models.<type>.<alias>]`, channels became
`[channels.<type>.<alias>]`, `[autonomy]` became `[risk_profiles.<alias>]`, and
agents became explicit `[agents.<alias>]` blocks that bind a model provider, a
risk profile, channels and cron jobs together.

Building against 0.7.5 would mean writing a config the current docs no longer
describe and the current image no longer accepts. **This distribution targets
0.8.4**, pinned by digest in the Dockerfile. Every deviation below follows from
reading that version.

---

## 1. Base image: `ghcr.io/zeroclaw-labs/zeroclaw:debian`, not Docker Hub, not `latest`

**Spec §7:** `FROM zeroclawlabs/zeroclaw:latest`.

Two problems:

1. `docker pull zeroclawlabs/zeroclaw` → `pull access denied … repository does
   not exist`. Official images go to GHCR:
   `ghcr.io/zeroclaw-labs/zeroclaw` (`docs/book/src/setup/container.md`).
2. The `latest` tag there is **distroless**
   (`gcr.io/distroless/cc-debian13:nonroot`, upstream `Dockerfile` stage
   `release`). No `sh`, no `apt`, no `install`. An entrypoint script cannot run
   in it and `kubectl`/`gh`/`envsubst` cannot be installed into it. Upstream
   says so explicitly: *"The default `latest` image is intentionally distroless
   and does not include `sh`, `ash`, or `bash`."*

**Deviation:** build on the `debian` tag, pinned to
`sha256:d2b3ac2e6b6dd3b0d977b3722fea8bc5ba414c2d5c34d48fe42838aac217afa5`. It
carries the same binary on `debian:trixie-slim`, is published multi-arch
(amd64 + arm64), and is the only variant this distribution can extend.

---

## 2. Secrets: env-var overrides, not `envsubst` of credentials

**Spec §5.1:** render channel tokens into `config.toml` with `envsubst` onto an
emptyDir.

**What 0.8 provides:** a generic env-override layer. `ZEROCLAW_<dotted__path>`
sets any config field, the value lands on the **in-memory** `Config` only, is
never persisted, is masked by `config save`, and is flagged with 💉 in
`config list` (`docs/book/src/reference/env-vars.md`). Verified working for
scalars and for `Vec<String>` (`gateway.paired_tokens`).

**Deviation:** `config.toml.tmpl` is still rendered with `envsubst`, but only
for **non-secret** shape — channel IDs, guild ID, cron expressions, model name,
namespace scope. Every credential is exported by `entrypoint.sh` as a
`ZEROCLAW_*` override:

| Secret env var | Config path it overrides |
|---|---|
| `ANTHROPIC_API_KEY` | `providers.models.anthropic.sre.api_key` |
| `SLACK_BOT_TOKEN` | `channels.slack.ops.bot_token` |
| `SLACK_APP_TOKEN` | `channels.slack.ops.app_token` |
| `DISCORD_BOT_TOKEN` | `channels.discord.ops.bot_token` |
| `ZC_WEBHOOK_SECRET` | `channels.webhook.alerts.secret` |
| `ZC_GATEWAY_TOKEN` | `gateway.paired_tokens` |

This is strictly stronger than the spec's design: the rendered config contains
no credential fields at all, so there is no file anywhere — image, emptyDir or
PVC — from which a token could be read.

### 2b. …which is why the rendered config lives on the PVC

**Spec §5.1 / §11.1:** the rendered config must be on an emptyDir, "never the
PVC", and the acceptance test asserts it is absent from the PVC.

ZeroClaw has **one install root**. `ZEROCLAW_CONFIG_DIR` takes precedence over
`ZEROCLAW_DATA_DIR`, and everything durable hangs off that same root: the
SQLite memory database, `receipts/`, SOP run state, the cron database,
`state/daemon_state.json`, `state/costs.jsonl`. Verified: with
`ZEROCLAW_CONFIG_DIR=/config ZEROCLAW_DATA_DIR=/data`, `zeroclaw doctor`
reports its workspace as `/config/data` — i.e. splitting the config onto an
emptyDir also moves **all persistent state** onto that emptyDir, silently
breaking FR7 on every restart.

**Deviation:** the install root is the PVC (`ZEROCLAW_CONFIG_DIR=/data`), and
the rendered `config.toml` (mode 0600) sits on it. The spec's reason for
keeping it off the PVC was that it would contain channel tokens; per §2 above
it contains none. The acceptance test was changed accordingly — `01-boot.sh`
asserts that the rendered config contains no credential field
(`api_key`, `bot_token`, `app_token`, `paired_tokens`, `secret =`, and any
`sk-ant-`/`xoxb-`/`xapp-`/`ghp_` literal) rather than asserting the file's
absence.

---

## 3. FR2: SOP webhook triggers do not fire — an adapter is required

**Spec §4/FR2:** a webhook trigger at `/sop/alert-investigate` receiving
Alertmanager's JSON.

Three findings, in increasing order of importance:

1. **There is no `/sop/*` route.** Not in 0.7.5, not in 0.8.4. The gateway's
   full route table (`crates/zeroclaw-gateway/src/lib.rs`) has `/webhook`,
   `/admin/sop/{pending,approve,deny}` and `/api/sops/*`, but no `POST /sop/…`.
   The SOP connectivity doc still describes one; the code does not have it.
2. **SOP webhook triggers have no producer.** The runtime says so in as many
   words (`crates/zeroclaw-runtime/src/sop/dispatch.rs`, `ingress_kind`):

   ```rust
   // `SopTrigger::Webhook` doc: "Defined and matched, but no live route feeds it."
   SopTriggerSource::Webhook => SopIngressKind::NotYetLive,
   ```
3. **`POST /webhook` is a plain chat endpoint.** It takes `{"message": "..."}`,
   runs the agent loop, and returns the reply. It does not attempt SOP
   dispatch. Alertmanager's payload shape is fixed and cannot be reshaped by
   configuration, so it cannot post there directly.

**Deviation:** a small Go sidecar, `alert-adapter/`, runs in the same pod:

```
Alertmanager --POST /alerts--> alert-adapter :9099 --POST /webhook--> gateway :42617
             X-Webhook-Secret                  Bearer + X-Webhook-Secret + X-Idempotency-Key
```

It verifies the shared secret in constant time **before** anything else, so a
wrong secret costs zero tokens and never reaches the model (spec acceptance
test 4 passes on the adapter, not on luck). It caps and frames the payload as
explicitly untrusted data, derives an idempotency key from the alert group's
own identity, and asks the agent to run the `alert-investigate` SOP through
`sop_execute`. The SOP keeps its `[[triggers]] type = "webhook"` block so the
intent is recorded and it starts working unchanged if upstream ever wires the
route.

The Service publishes **only** the adapter's port 9099. The gateway port is
pod-local except for kubelet probes and the optional metrics Service.

**Non-interactive gateway auth** (a spec open question): `[gateway]` has no
`token` field, but `paired_tokens: Vec<String>` is a real config field. Seeding
it from `ZC_GATEWAY_TOKEN` gives the adapter a working bearer with
`require_pairing = true` still on and no interactive `POST /pair` step.
Verified: `💉 gateway.paired_tokens = ["…"] (Vec<String>) 🔒`.

**Webhook secret plumbing:** the gateway reads the `X-Webhook-Secret`
comparison value from `config.channels.webhook.values().next()` — the first
webhook *channel* block, regardless of whether that channel is enabled. So the
config defines one disabled `[channels.webhook.alerts]` block purely to carry
the secret; nothing binds its port.

**Alertmanager header support:** Alertmanager ≥ 0.27 can set custom headers
(`http_config.http_headers`). Older builds cannot, so the adapter also accepts
the same secret as an `Authorization: Bearer` credential. Both forms are
constant-time compared; a wrong `X-Webhook-Secret` is never rescued by a valid
bearer.

---

## 4. Channel config keys differ from the spec sketch

Verified against `SlackConfig` / `DiscordConfig` in the 0.8.4 schema:

| Spec §5.3 | 0.8.4 actual |
|---|---|
| `[channels.discord]` | `[channels.discord.<alias>]` (alias-keyed map) |
| `allowed_guilds = [...]` | `guild_ids = [...]` |
| `reply_to_mentions_only` | `mention_only` |
| `[channels.slack]` | `[channels.slack.<alias>]` |
| `signing_secret = "..."` | **does not exist** |
| `channel_ids = [...]` | `channel_ids = [...]` ✓ |
| `allowed_users` (both channels) | **does not exist** |

Two consequences worth calling out:

- **`SLACK_SIGNING_SECRET` is not used.** Socket Mode authenticates with the
  app token; there is no signing secret to configure. The variable is still
  accepted (and logged as unused) so a Secret written from the spec's variable
  list does not break.
- **The operator roster moved.** 0.8 dropped per-channel `allowed_users`;
  authorisation for approvals now comes from
  `[peer_groups.<name>].external_peers`. `ZC_ALLOWED_USERS` therefore renders
  into two peer groups (`ops_slack`, `ops_discord`). **With it empty, nobody
  can approve a rightsizing patch** — the entrypoint warns loudly about this
  rather than letting it be discovered at 03:00.

Also: `[secrets] backend = "none"` (spec §5.3) does not exist. `SecretsConfig`
has exactly one field, `encrypt: bool`; this distribution sets
`encrypt = false`, which is a no-op in practice because nothing writes a
credential to the config in the first place.

`[autonomy] forbidden_commands` also no longer exists. 0.8's
`RiskProfileConfig` has `allowed_commands` (a strict allowlist — anything
unlisted is refused) plus `block_high_risk_commands`. Both are set.

---

## 5. FR1/FR3 schedules: cron *jobs*, not SOP cron triggers

SOP cron triggers do fire (`check_sop_cron_triggers` is called from the
daemon's maintenance tick), but the tick has no agent loop, so the run starts
and its first `ExecuteStep` is only **logged as pending**
(`process_headless_results`). A cron-triggered SOP would therefore never
actually sweep anything.

**Deviation:** the schedules live in declarative `[cron.<alias>]` jobs with
`job_type = "agent"`, whose prompt enters the SOP through the in-agent
`sop_execute` tool — that path owns a real agent loop. The SOPs keep
`[[triggers]] type = "manual"` and are bound to the agent via
`[agents.sre].cron_jobs`. `SWEEP_CRON` / `RIGHTSIZE_CRON` (plus
`HEARTBEAT_CRON` for the once-daily liveness line) are substituted into those
job definitions.

One limitation this inherits: a cron job's `delivery` block names **one**
channel. The digest therefore goes to Slack via `delivery` and to Discord via
`send_via(target: "discord.ops", body: …)` in the same turn, which is why
`peer_groups` exist for both channels — `send_via` refuses a target that is not
covered by a peer group the agent belongs to
(`crates/zeroclaw-tools/src/send_via.rs`, `resolve_target`).

---

## 6. Sandbox: `none` in-cluster, deliberately

**Spec §8:** "attempt `landlock`, fall back to `none` with a logged warning".

ZeroClaw's Landlock backend is an **allowlist**, and it does not read
`forbidden_paths`. It permits exactly: the workspace, `/tmp`, `/usr`, `/bin`,
`/lib`, `/lib64`, `/etc/ld.so.*` and `/dev/null`
(`crates/zeroclaw-runtime/src/security/landlock.rs`, `build_ruleset`). Nothing
else — including `/var/run/secrets/kubernetes.io/serviceaccount/`.

Every shell tool call runs as a child process with that ruleset applied via
`pre_exec`. With Landlock active, `kubectl` cannot read the projected
ServiceAccount token or the cluster CA, so **in-cluster authentication fails
entirely**. That is not a fallback situation the runtime detects; it is a
working sandbox doing exactly what it was told, breaking the one thing this
agent exists to do.

**Deviation:** `ZC_SANDBOX_BACKEND=none` (a ConfigMap value, so an operator can
change it knowingly). The isolation boundary is the container plus RBAC:
`runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`,
all capabilities dropped, `seccompProfile: RuntimeDefault`, and a ClusterRole
with no destructive verb in it.

This also resolves the spec's `forbidden_paths` question in §5.3. Both halves
of the intent hold: `/var/run/secrets` stays in `forbidden_paths`, which stops
the **agent's** file tools and shell arguments from reading the token, while
`kubectl` — a subprocess opening the file itself, not a path handed to a tool —
authenticates normally.

Note also that the Docker sandbox backend would need a Docker socket in the
pod, which is a far larger hole than the one it would close; it is never used
here, as the spec requires.

---

## 7. `TEST.sh` is a test table, not a shell script

`zeroclaw skills test` does not execute `TEST.sh`. It parses it line by line as
`command | expected_exit | expected_output_pattern`, runs each command with
`sh -c` and cwd set to the skill directory, and matches the pattern against
stdout+stderr as a regex then as a substring
(`crates/zeroclaw-runtime/src/skills/testing.rs`). A conventional shell script
yields zero parsed cases and reports "No TEST.sh found".

The skill's `TEST.sh` is written in that format (25 cases, all passing in the
built image). Because the parser splits on `" | "`, no test command may contain
a spaced shell pipe; the jq assertions therefore call
`tests/jq-fixture.sh`, which owns the pipes and the fixtures.

---

## 8. Repo layout differences

| Spec §2 | Here | Why |
|---|---|---|
| `ci/pipeline.yaml` | `.github/workflows/{ci,release}.yaml` + `Makefile` | The spec allows "Makefile targets equivalent". The workflows only call `make`, so local and CI runs are the same commands. |
| — | `alert-adapter/` | §3 above. |
| — | `deploy/configmap.yaml` | Non-secret tunables kept out of the Secret so they can be reviewed and diffed. |
| — | `deploy/networkpolicy.yaml` | Optional; k3s's default Flannel has no policy controller, which the file says plainly. |
| `/root/.zeroclaw` (PVC mount) | `/data` | The pod runs as uid 65534 under `runAsNonRoot`; `/root` is not writable by it. |

---

## 9. What has *not* been verified here

Stated plainly, because the difference matters:

**Verified against real artifacts**

- the rendered config parses and every key resolves — `zeroclaw config list`
  against the 0.8.4 binary, with the `💉` markers confirming the secret
  overrides land;
- all four SOPs — `zeroclaw sop validate` → 4/4 valid;
- the skill — `zeroclaw skills audit` clean, `zeroclaw skills test` 25/25;
- `zeroclaw doctor` inside the built image — 17 ok, 0 errors;
- the image builds and the entrypoint renders, validates, syncs and fails fast
  on missing env (`make build image-test image-scan`);
- the adapter's auth, idempotency, framing and truncation — Go unit tests;
- shellcheck, YAML parsing, TOML round-trip, `gitleaks`-shaped literal scans.

**Not executed**

- **the k3d acceptance suite** (`tests/e2e/`). `k3d` is not installed on this
  machine, so the suite is written and lint-clean but has never been run. CI
  runs it on every push; the first green run there is the real signal.
- **anything requiring a live model call or live chat credentials** — the
  digest wording, the proposal table, the dedupe search. The suite exercises
  these when `ANTHROPIC_API_KEY` (and, for dedupe, `GH_TOKEN` +
  `E2E_GH_REPO`) are present, and skips them loudly otherwise rather than
  asserting against a mock that would prove nothing.
- **the multi-arch build.** Only `linux/arm64` was built locally (this is an
  arm64 host). The Dockerfile is arch-parameterised (`TARGETARCH` for the
  adapter, kubectl and gh) and the release workflow builds both, but amd64 has
  not been produced yet.

---

## 10. Open questions for the operator

1. **kubectl skew.** Pinned to `v1.36.3` to match current stable k3s
   (`v1.36.3+k3s1`). Kubernetes supports ±1 minor between client and API
   server, so this image is good for k3s 1.35–1.37. Bump `KUBECTL_VERSION` in
   the Dockerfile when the cluster moves outside that window.
2. **Rightsizing evidence quality.** `kubectl top` gives an instantaneous
   sample, not a p95. The SOP compensates by storing each run's observations
   under `rightsize:<workload>` and building a percentile over runs, so the
   first weekly run is the weakest one. If real percentiles matter more than
   avoiding a Prometheus dependency, that is the thing to revisit — but it is
   out of scope for v1 per §12.
3. **Slack Block Kit approvals.** The spec asks for buttons. 0.8's approval
   surface for Slack is driven by the runtime's own approval flow; this
   distribution does not add custom Block Kit payloads, so approvals appear as
   the runtime renders them (and out-of-band via
   `zeroclaw sop approve` / `POST /admin/sop/approve`). Worth confirming
   against a live workspace before anyone relies on a specific button UI.
