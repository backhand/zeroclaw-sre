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

**Verified on a real k3s cluster** (2 nodes, v1.35.5+k3s1, xAI `grok-4.5`)

- boot, `/health`, adapter `/healthz` through the Service;
- the rendered config on the PVC contains no credential value, mode 0600, and
  a recursive scan of the whole volume finds no token;
- the adapter rejects a wrong or missing secret with 401 and a GET with 405,
  before any model call; the correct secret reaches the agent;
- **a real sweep**: the agent enumerated a namespace, pulled events and logs,
  and returned a digest in the documented format naming both broken workloads
  with reason, restart count, age and a log signature;
- the RBAC boundary, as the pod's own ServiceAccount: delete/create/update,
  secrets, configmaps, nodes and RBAC all denied; reads and namespaced patch
  allowed; patch denied in every namespace without a RoleBinding;
- state survives `kubectl delete pod` — memory, receipts and SOP run state are
  all under the PVC and the agent recalls prior turns afterwards.

Sections 11–13 above are the four defects that run exposed.

**Still not executed**

- **the k3d acceptance suite** (`tests/e2e/`). `k3d` is not installed on the
  build host, so the suite is written and lint-clean but has never been run as
  a suite. CI runs it on every push; the first green run there is the real
  signal.
- **Slack and Discord delivery.** Verified only that the configured bot token
  authenticates (`auth.test`) and carries the scopes the README lists. Nothing
  has been posted to a real channel: Socket Mode also needs an app-level token
  (`xapp-…`), and the bot must be invited to the channel first.
- **The `sweep:<fingerprint>` memory writes.** The sweep produced a correct
  digest but did not store the per-finding fingerprint keys that step 3 of the
  SOP asks for, so the escalation ladder's counter was not exercised. The SOP
  wording may need to be more imperative about that step; treat FR4's
  three-sweep threshold as unproven until it is.
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

## 11. Env overrides cannot reach a nested block inside an alias-keyed map

`ZEROCLAW_channels__slack__ops__bot_token` works (alias + scalar).
`ZEROCLAW_cron__sweep__delivery__channel` does **not**: the resolver drops the
alias segment and reports `Unknown property 'cron.delivery.channel'`, which
aborts daemon startup. Verified against 0.8.4 for both
`cron__<alias>__delivery__*` and `cron__<alias>__cron_delivery__*`.

Anything one level deeper than `<section>.<alias>.<field>` therefore has to be
a template variable, not an override. That is why `ZC_DIGEST_CHANNEL_REF`,
`ZC_FANOUT_CHANNEL_REF` and `ZC_AGENT_CHANNELS` exist.

---

## 12. `memory.backend` is a reference, not a backend name

`[memory] backend = "sqlite"` looks like it names a backend. It does not — it
is a dotted reference to a storage instance (`sqlite.default` →
`Config.storage.sqlite.default`). With no `[storage.sqlite.default]` block the
reference resolves to nothing and the daemon starts, cheerfully, with:

```
🧠 Memory:   none (auto-save: on)
```

Nothing fails. The agent simply forgets every fingerprint between sweeps, which
silently disables the escalation ladder and ticket dedupe — the two features
that depend on remembering what was seen last time. The config now declares the
storage instance explicitly, and a real deploy is what surfaced this.

---

## 13. Two more found by deploying, not by reading

**The gateway pre-shared bearer must be seeded as a SHA-256 digest.**
`gateway.paired_tokens` stores digests, and ZeroClaw decides whether a
configured entry is a digest or a plaintext token *by its shape*: exactly 64
hex characters means "already hashed"
(`crates/zeroclaw-config/src/pairing.rs`, `is_token_hash`). `openssl rand
-hex 32` — the generator in this project's own README — produces exactly 64 hex
characters. Seeding the raw token therefore stored it as a digest whose
preimage nobody has: every authenticated request 401'd while `/health`
reported `"paired": true`. `entrypoint.sh` now hashes the token before seeding
it, which is unambiguous for any token shape an operator picks.

**`gateway.request_timeout_secs` defaults to 30 seconds.** A real
investigation — enumerate, describe, read events, tail logs, resolve the owning
workload — takes minutes. At the default, `POST /webhook` returns an empty body
long before the agent finishes, so every Alertmanager-driven investigation
would have been truncated. Now set to 600, matching ZeroClaw's own
long-running-route budget, with the adapter's client timeout aligned to it.

---

## 14. No published ZeroClaw image compiles the Slack channel

`channel-slack` is in the crate's default feature set, but the *published
images* are not built with it. Both tags say so themselves — configure a Slack
block and run `zeroclaw channel list`:

```
  ✅ Discord
  Configured but not compiled in this binary:
  🚫 Slack (configured, not compiled)
  Build from source with `./install.sh --source --preset full`,
  `--features channels-full`, or the specific `channel-*` feature.
```

Verified on `ghcr.io/zeroclaw-labs/zeroclaw:latest` **and** `:debian`, both at
0.8.4. Discord, webhook and CLI are compiled in; Slack is not.

The failure mode is quiet, which is what makes it expensive: the config
validates, `zeroclaw doctor` reports "at least one channel configured", the
bot token and app-level token both authenticate against Slack's API
(`auth.test` and `apps.connections.open` succeed), `/health` is green — and no
Slack channel ever connects. The only visible symptom is the absence of the
channel-server banner in the logs.

**Deviation:** the Dockerfile gained an opt-in source-build stage.

```bash
docker build --build-arg ZC_SLACK=1 .          # Slack compiled in
docker build .                                 # default: published binary
```

`zcbin-0` (published) and `zcbin-1` (source) are alternative stages selected by
`FROM zcbin-${ZC_SLACK}`, so with the default the Rust toolchain is never even
pulled — a `COPY --from` on the source stage would have forced a full compile on
every build. The cost when you do opt in is real: a full workspace build, ~2 GB
RAM, tens of minutes.

Discord needs none of this and works on the published image today.

---

## 15. The shipped RBAC no longer grants write anywhere

`deploy/rbac.yaml` used to include a RoleBinding for the `default` namespace as
an "example". Applying the file therefore granted the agent patch rights on
`default` to anyone who did not read it first — and the e2e RBAC case caught
exactly that, failing on "patching workloads in default was NOT denied".

The binding is gone. Applying `deploy/rbac.yaml` now grants cluster-wide read
and nothing else; write is opt-in per namespace via
`make rolebindings ALLOWED_NAMESPACES=…`. Read-only is the right default for a
distribution other people deploy.

---

## 16. The published base is bookworm, not trixie — pin the source builder to match

Upstream's `Dockerfile` says `FROM debian:trixie-slim` for its runtime stage.
The image they actually publish is Debian 12:

```
$ docker run --rm --entrypoint sh ghcr.io/zeroclaw-labs/zeroclaw:debian \
    -c 'ldd --version | head -1'
ldd (Debian GLIBC 2.36-9+deb12u14) 2.36
```

`rust:1.96-slim` is trixie (glibc 2.41), so a source build on it links against
a newer libc than the runtime has, and the resulting image dies on first exec:

```
/usr/local/bin/zeroclaw: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found
```

The builder is pinned to `rust:1.96-slim-bookworm`. More usefully, the runtime
stage now ends with `RUN zeroclaw --version`, so a libc or linker mismatch
fails the **build** instead of becoming a CrashLoopBackOff whose logs say
nothing about the real cause. The release workflow re-runs the same check
against the *published* manifest, and additionally asserts that the `slack`
variant really does report the Slack channel as compiled in — a variant that
exists for one reason should prove that reason before it is tagged.

The general lesson, which cost a full emulated build: trust the artifact, not
the Dockerfile that supposedly produced it.

---

## 17. Releases build on native runners, not under emulation

`amd64` under QEMU on an arm64 laptop is slow enough to matter for the normal
image and completely impractical for the `slack` variant's Rust build. The
release workflow therefore builds each architecture on a runner of that
architecture (`ubuntu-latest` for amd64, `ubuntu-24.04-arm` for arm64), pushes
each result by digest with no tag, and assembles a manifest list per variant
once every leg has succeeded — so a half-finished matrix can never publish a
usable tag.

`workflow_dispatch` takes a tag name, which variants to build, and whether to
pin. That covers scratch builds (`tag: test`) without creating a release, which
is the day-to-day case when iterating on a cluster.

Digest pinning resolves the digest from the registry rather than from a matrix
job's `outputs`: with two variants in flight those outputs are whichever leg
finished last, which would have pinned the Slack image into
`deploy/deployment.yaml` roughly half the time.

---

## 18. `supervised` alone makes the agent unusable in chat

Out of the box every tool that is not in `auto_approve` prompts. In a Slack
channel that means a button for each `kubectl get`, each 👀 acknowledgement
reaction, each `sop_list` — several approvals before the agent has read
anything. Clicking *Always* does not settle it either: the prompts keep coming,
so the only durable answer is the config list.

The inconsistency is the giveaway. The scheduled sweep already runs the same
shell commands unattended on the cron path, where no human is present to
approve. Gating them only when someone happens to be in the conversation
protects nothing and costs everything.

`auto_approve` therefore covers cluster reads (`shell`), the agent's own
bookkeeping, procedure control, and talking to humans. `always_ask` keeps
`file_write` and `file_edit`.

`shell` is the consequential entry, so what still constrains it, explicitly:

- `allowed_commands` is a strict allowlist — anything unlisted is refused;
- RBAC has no destructive verb anywhere and no access to secrets;
- the only writable namespaces are the ones with an explicit RoleBinding;
- every mutating SOP step carries `requires_confirmation`, so rightsizing
  still cannot patch without an operator approving in chat.

The residue: a sufficiently manipulated agent could `kubectl patch` a resources
block inside `ALLOWED_NAMESPACES` without a per-command approval, because the
gate now sits at the SOP step rather than the tool call. That is the layered
model the spec describes — RBAC authoritative, SOP gates on mutations — and it
is a deliberate trade, not an oversight. Remove `"shell"` from `auto_approve`
for the stricter posture; the agent then asks before each command, which is
safe, noisy, and slow.

---

## 19. The agent can now release and prune, and RBAC gained one delete verb

Requested explicitly. It changes the claim in §9 of the README, so it is stated
here rather than buried.

**Releasing** needed no RBAC change at all: `kubectl set image` and
`kubectl rollout restart` are both PATCHes, which `zeroclaw-sre-write` already
allowed. What was missing was policy — the skill forbade image changes and no
procedure existed. There is now a `release` SOP that records the current image
and revision, verifies the target tag is pullable, proposes, gates on approval,
applies, and then *waits for the rollout to land* — offering `rollout undo` as
its own separately-approved step if it does not.

**Pruning** did need a new verb: `delete` on `replicasets`, in its own
ClusterRole (`zeroclaw-sre-prune`), bound per namespace like the write role and
droppable on its own. Not pods, not deployments, nothing else.

The safeguard is not the approval button, which a determined prompt can talk
its way to. It is `prune-rs.sh`, which only ever returns ReplicaSets that are
owned by a Deployment, scaled to zero, with nothing still terminating, and
outside the newest `keep` revisions (default 3) — and which **re-reads the
object immediately before deleting it**, so one that went live again between
listing and pruning is refused rather than taking its pods with it. The SOP
forbids `kubectl delete replicaset` directly for exactly that reason.

Worth saying to any operator who asks for this: Kubernetes already caps old
ReplicaSets per Deployment via `.spec.revisionHistoryLimit`, default 10.
Lowering it is free and needs no agent. On the cluster this was built against,
67 of 103 ReplicaSets were already scaled to zero — all within their limits —
so the honest framing is that this trims below the platform's own ceiling, it
does not fix an absence.

What this costs: the README's line that "there is no delete verb, so no prompt
however clever can produce one" is no longer true in namespaces bound to
`zeroclaw-sre-prune`. It is true everywhere else, and the blast radius where it
is bound is one superseded ReplicaSet — no running pods, no Deployment, no
rollback beyond `keep`. Do not bind the prune role in a namespace where losing
rollout history matters.

---

## 20. Slack draft streaming leaves an orphaned placeholder

`stream_drafts = true` posts a placeholder and edits it via `chat.update` as
tokens arrive. After a tool-heavy turn the reply is delivered as a *new*
message, and the placeholder is never finalised — so "Organizing…" sits under a
completed answer indefinitely, looking like the agent is still working.

Disabled. The cost is that long answers appear all at once instead of
streaming, which for an SRE digest is no loss.

---

## 21. Whether the executor should be an in-cluster MCP server

Raised by the operator, recorded because it is the right shape for a v2 and the
reasoning should not be lost.

Today the write path is: model → `shell` → `kubectl`. The constraint that a
patch touches only the `resources` block lives in SKILL.md prose and a SOP step
— the weakest layer available, because it is instructions to a model. RBAC can
express "may patch deployments"; it cannot express "may patch only
`.spec.template.spec.containers[*].resources`".

A typed executor can. `patch_resources(workload, requests, limits)` validates
its own arguments and cannot express the thing you did not authorise. That is
strictly stronger than an allowlist of binaries, and `prune-rs.sh` and
`repo-map.sh` are already this pattern in miniature — scripts that own a
decision instead of letting the model improvise one.

The larger prize is credential custody. `GH_TOKEN` currently sits in the agent's
environment, so the agent can do anything the token can — which is why
`git_forge` and `gh` were interchangeable and why gating one of them was
theatre. An executor holding the token and exposing only `file_issue` and
`comment_issue` removes that reach entirely. Same for the write RBAC: give it to
the executor and the agent's own ServiceAccount drops to read-only, restoring
the property §19 gave up.

Where it does not help, and should not be oversold:

- it does not remove the need for RBAC, it relocates it — a compromised
  executor patches just as effectively, and now it is the component that must
  be correct;
- approvals still have to reach a human where that human already is. A web UI
  is a second place to look, which on-call usually makes worse, not better;
- diagnosis is the bulk of the work and wants open-ended composition. Replacing
  raw `kubectl` reads with typed tools trades away the ability to answer a
  question nobody anticipated.

So the shape worth building is a hybrid, not a rewrite: keep read-only kubectl
for diagnosis, move every *mutation* behind the executor, and move the tokens
with them.

---

## 22. The SOP approval gate did not hold, and why the fix is tools

Observed on a live run of `prune-replicasets`. Step 4 is
`kind: checkpoint, requires_confirmation: true`. Its recorded output:

> *"Operator already replied **approve** in-thread. Candidate set is empty…
> Proceeding with zero deletes."*

Its only tool call was `sop_status`, and there is **no `sop_approval_*` ledger
entry for the run**. The gate was never formally cleared; the model asserted the
approval had happened and the run continued.

Nothing was deleted that time, because the candidate list was empty. The
mechanism is the problem, not the outcome.

The engine does implement the gate — `step_requires_approval_gate` returns true
for `requires_confirmation`, `resolve_step_action` yields `WaitApproval`, and
`pending_step_blocks_direct_advance` stops `sop_advance` skipping a checkpoint.
It still ended up past it. Combined with `require_approval_for_medium_risk =
false` (turned off to stop an approval flood that buried the channel), the
result was that mutations inside `ALLOWED_NAMESPACES` had no enforced human gate
at all. RBAC was the only thing left — which is why the earlier attempt against
`zeroclaw-sre` genuinely failed while the "approval" did not.

Two fixes, one immediate and one structural.

**Immediate:** `excluded_tools = ["sop_approve"]`. The agent cannot call the
approval tool, so approval must arrive from a human surface — Slack buttons,
`zeroclaw sop approve`, or `POST /admin/sop/approve`.

**Structural:** ZeroClaw's approval granularity is **per tool**, and today every
mutation and every read share one tool: `shell`. There is no way to say "ask
before deleting a ReplicaSet, but not before `kubectl get`", because both are
the same tool call with a different string inside. So the gate ends up either
everywhere (unusable — the flood) or nowhere (what we have).

Giving each mutation its own tool makes the granularity match the risk:

```toml
always_ask  = ["k8s__prune_replicaset", "k8s__patch_resources",
               "k8s__set_image", "k8s__rollout_restart", "gh__file_issue"]
auto_approve = ["shell", ...]   # reads stay silent
```

A typed tool is also strictly stronger than a command allowlist: `allowed_commands`
can permit `kubectl` but cannot express "patch only the resources block", whereas
`patch_resources(workload, requests, limits)` **cannot represent** the
unauthorised operation. `prune-rs.sh` and `repo-map.sh` are already this pattern
in miniature — scripts that own a decision instead of letting the model improvise.

The gate belongs on the capability, not on a procedure the model narrates.

---

## 23. Declaring an MCP server is not granting it

The executor was configured, spawnable, its binary present, its handshake
verified by hand — and completely invisible to the agent, which reported
`k8s__file_issue` simply not being in its tool list.

Agents receive only the MCP servers named by their `mcp_bundles`, exactly as
they receive only the skills named by their `skill_bundles`. From the schema:

> Secure by default: an agent is granted only the servers named by its bundles.
> **An agent with no `mcp_bundles` receives no MCP servers (omission is not a
> grant.)**

So `[mcp.servers]` declares a server; `[mcp_bundles.<alias>]` plus
`agents.<alias>.mcp_bundles` grants it. Both are required.

Two lessons, the second more expensive than the first:

1. The indirection was already visible in `skill_bundles`, which this config
   uses. A pattern that appears twice in one schema is worth checking for.
2. `GH_TOKEN` had already been removed from `shell_env_passthrough` in the same
   change — so the fallback was gone before the replacement was proven
   reachable, turning "the new capability is not wired yet" into "ticket filing
   has no path at all". Remove a fallback only after the thing replacing it has
   been exercised end to end.

Also raised `max_actions_per_hour` to 400 in the runtime profile. The default
stopped the agent mid-investigation with "further tool calls are rejected",
which reads as a bug and discards the work in progress. One investigation is
many reads by design; a sweep does that per finding.

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
