#!/usr/bin/env bash
# zeroclaw-k3s-sre entrypoint.
#
#   validate env  ->  render config  ->  sync distro workspace  ->  exec daemon
#
# Secrets never reach the rendered config: they are re-exported as
# ZEROCLAW_<dotted__path> overrides, which ZeroClaw applies to the in-memory
# Config only (never persisted, masked on `config save`). The rendered
# config.toml holds shape and schedules, nothing confidential.

set -euo pipefail

log()  { printf '%s zeroclaw-sre: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

# ── 0. Paths ─────────────────────────────────────────────────────
# ZeroClaw has ONE install root: ZEROCLAW_CONFIG_DIR wins over
# ZEROCLAW_DATA_DIR, and everything durable (SQLite memory, receipts, SOP run
# state, cron DB, daemon state, cost log) hangs off it. Splitting the rendered
# config onto a separate emptyDir would therefore split the *state* off the PVC
# too, so the root is the PVC and the rendered config sits on it — carrying no
# credentials at all, because every secret is an in-memory env override.
# NOTES.md §2.
: "${ZEROCLAW_CONFIG_DIR:=/data}"
: "${DISTRO_DIR:=/opt/distro}"
export ZEROCLAW_CONFIG_DIR

ZC_DATA_DIR="$ZEROCLAW_CONFIG_DIR"
ZC_WORKSPACE_DIR="${ZC_WORKSPACE_DIR:-$ZEROCLAW_CONFIG_DIR/workspace}"

# ── 1. Required environment ──────────────────────────────────────
required=(
  ANTHROPIC_API_KEY
  DISCORD_BOT_TOKEN
  DISCORD_GUILD_ID
  SLACK_BOT_TOKEN
  SLACK_APP_TOKEN
  SLACK_CHANNEL_IDS
  ZC_WEBHOOK_SECRET
  ZC_GATEWAY_TOKEN
)
missing=()
for var in "${required[@]}"; do
  if [ -z "${!var:-}" ]; then missing+=("$var"); fi
done
if [ ${#missing[@]} -gt 0 ]; then
  log "missing required environment variables:"
  for var in "${missing[@]}"; do log "  - $var"; done
  log "see README.md 'Creating the Secret' — every one of these comes from the"
  log "zeroclaw-sre Secret; the pod cannot start without them."
  exit 78   # EX_CONFIG
fi

# SLACK_SIGNING_SECRET is accepted but unused: Socket Mode authenticates with
# app_token, and 0.8.x SlackConfig has no signing_secret field (NOTES.md §4).
if [ -n "${SLACK_SIGNING_SECRET:-}" ]; then
  log "note: SLACK_SIGNING_SECRET is set but unused (Socket Mode needs no signing secret)"
fi

# ── 2. Optional environment, with documented defaults ────────────
: "${ZC_MODEL:=claude-sonnet-4-5}"
: "${ZC_SANDBOX_BACKEND:=none}"      # see NOTES.md §6 before changing
: "${ZC_WEBHOOK_PORT:=42618}"        # never bound; the block only carries `secret`
: "${SWEEP_CRON:=*/15 * * * *}"
: "${RIGHTSIZE_CRON:=0 6 * * 1}"
: "${HEARTBEAT_CRON:=0 7 * * *}"
: "${ALLOWED_NAMESPACES:=}"
: "${GH_REPO:=}"
: "${SLACK_DIGEST_CHANNEL:=}"
: "${DISCORD_DIGEST_CHANNEL:=}"
: "${DISCORD_CHANNEL_IDS:=}"
: "${ZC_ALLOWED_USERS:=}"
: "${ZC_ALLOWED_USERS_SLACK:=$ZC_ALLOWED_USERS}"
: "${ZC_ALLOWED_USERS_DISCORD:=$ZC_ALLOWED_USERS}"

if [ -z "${GH_TOKEN:-}" ] || [ -z "$GH_REPO" ]; then
  log "WARNING: GH_TOKEN/GH_REPO unset — ticket filing (FR4) is disabled."
  log "         Findings will be reported to chat only; the file-ticket SOP will refuse to run."
  export GH_ENABLED=false
else
  export GH_ENABLED=true
fi

if [ -z "$ALLOWED_NAMESPACES" ]; then
  log "note: ALLOWED_NAMESPACES unset — all namespaces are readable, and no"
  log "      namespace is writable (rightsizing needs an explicit list)."
fi

# The digest lands wherever the operator points it; default to the first
# configured Slack channel so a minimal Secret still works.
if [ -z "$SLACK_DIGEST_CHANNEL" ]; then
  SLACK_DIGEST_CHANNEL="${SLACK_CHANNEL_IDS%%,*}"
fi
if [ -z "$DISCORD_DIGEST_CHANNEL" ] && [ -n "$DISCORD_CHANNEL_IDS" ]; then
  DISCORD_DIGEST_CHANNEL="${DISCORD_CHANNEL_IDS%%,*}"
fi

# ── 3. CSV -> TOML array literals ────────────────────────────────
# "C123,C456" -> "C123", "C456"   |   "" -> "" (empty array)
csv_to_toml_list() {
  local csv="$1" out="" item
  local IFS=,
  for item in $csv; do
    item="${item#"${item%%[![:space:]]*}"}"   # ltrim
    item="${item%"${item##*[![:space:]]}"}"   # rtrim
    [ -n "$item" ] || continue
    if [ -n "$out" ]; then out="$out, "; fi
    out="$out\"$item\""
  done
  printf '%s' "$out"
}

SLACK_CHANNEL_IDS_TOML="$(csv_to_toml_list "$SLACK_CHANNEL_IDS")"
DISCORD_GUILD_IDS_TOML="$(csv_to_toml_list "$DISCORD_GUILD_ID")"
DISCORD_CHANNEL_IDS_TOML="$(csv_to_toml_list "$DISCORD_CHANNEL_IDS")"
ZC_ALLOWED_USERS_SLACK_TOML="$(csv_to_toml_list "$ZC_ALLOWED_USERS_SLACK")"
ZC_ALLOWED_USERS_DISCORD_TOML="$(csv_to_toml_list "$ZC_ALLOWED_USERS_DISCORD")"

if [ -z "$ZC_ALLOWED_USERS_SLACK_TOML" ] && [ -z "$ZC_ALLOWED_USERS_DISCORD_TOML" ]; then
  log "WARNING: ZC_ALLOWED_USERS unset — no operator is registered as a peer, so"
  log "         approval prompts and ad-hoc questions have nobody to answer them."
  log "         Rightsizing will propose but can never be approved. Set it."
fi

export ZC_MODEL ZC_DATA_DIR ZC_WORKSPACE_DIR ZC_SANDBOX_BACKEND ZC_WEBHOOK_PORT \
       SLACK_CHANNEL_IDS_TOML SLACK_DIGEST_CHANNEL \
       DISCORD_GUILD_IDS_TOML DISCORD_CHANNEL_IDS_TOML DISCORD_DIGEST_CHANNEL \
       ZC_ALLOWED_USERS_SLACK_TOML ZC_ALLOWED_USERS_DISCORD_TOML \
       SWEEP_CRON RIGHTSIZE_CRON HEARTBEAT_CRON ALLOWED_NAMESPACES GH_REPO

# ── 4. Render the config (non-secret substitution only) ──────────
# Explicit variable list: envsubst leaves every other $NAME untouched, so a
# stray shell-looking token in a prompt can never be eaten.
# shellcheck disable=SC2016  # the literal ${NAME} tokens are envsubst's input, not shell expansions
SUBST_VARS='${ZC_MODEL} ${ZC_DATA_DIR} ${ZC_WORKSPACE_DIR} ${ZC_SANDBOX_BACKEND}
${ZC_WEBHOOK_PORT} ${SLACK_CHANNEL_IDS_TOML} ${SLACK_DIGEST_CHANNEL}
${DISCORD_GUILD_IDS_TOML} ${DISCORD_CHANNEL_IDS_TOML} ${DISCORD_DIGEST_CHANNEL}
${ZC_ALLOWED_USERS_SLACK_TOML} ${ZC_ALLOWED_USERS_DISCORD_TOML}
${SWEEP_CRON} ${RIGHTSIZE_CRON} ${HEARTBEAT_CRON} ${ALLOWED_NAMESPACES} ${GH_REPO}'

mkdir -p "$ZEROCLAW_CONFIG_DIR"
if [ ! -w "$ZEROCLAW_CONFIG_DIR" ]; then
  die "$ZEROCLAW_CONFIG_DIR is not writable — check the PVC mount and the pod's fsGroup"
fi
umask 077
envsubst "$SUBST_VARS" \
  < "$DISTRO_DIR/config/config.toml.tmpl" \
  > "$ZEROCLAW_CONFIG_DIR/config.toml"
chmod 0600 "$ZEROCLAW_CONFIG_DIR/config.toml"
log "rendered $ZEROCLAW_CONFIG_DIR/config.toml (no secrets substituted)"

# A malformed config is NOT a hard error in ZeroClaw: it warns and silently
# falls back to defaults for the whole file, which would boot an agent with no
# channels, no schedule and no SOPs. Turn that into a crash instead.
if zeroclaw config list 2>&1 >/dev/null | grep -q 'malformed and was reset to defaults'; then
  log "rendered config failed to parse; ZeroClaw would have fallen back to defaults."
  zeroclaw config migrate 2>&1 | sed 's/^/    /' >&2 || true
  die "config render is invalid — refusing to start"
fi

# ── 5. Secrets -> in-memory config overrides ─────────────────────
# Human-readable Secret keys on the left, ZeroClaw schema paths on the right.
export ZEROCLAW_providers__models__anthropic__sre__api_key="$ANTHROPIC_API_KEY"
export ZEROCLAW_channels__slack__ops__bot_token="$SLACK_BOT_TOKEN"
export ZEROCLAW_channels__slack__ops__app_token="$SLACK_APP_TOKEN"
export ZEROCLAW_channels__discord__ops__bot_token="$DISCORD_BOT_TOKEN"
export ZEROCLAW_channels__webhook__alerts__secret="$ZC_WEBHOOK_SECRET"
export ZEROCLAW_gateway__paired_tokens="$ZC_GATEWAY_TOKEN"

# ── 6. Sync the distro payload into the live workspace ───────────
# Distro-owned trees are replaced wholesale on every boot: an image tag bump is
# the upgrade path for skills and SOPs. State (*.db, receipts/, state/, runs/)
# lives beside them on the PVC and is never touched here.
mkdir -p "$ZC_WORKSPACE_DIR"
for tree in skills sops; do
  src="$DISTRO_DIR/workspace/$tree"
  dst="$ZC_WORKSPACE_DIR/$tree"
  [ -d "$src" ] || die "distro payload missing: $src"
  rm -rf "${dst:?}.incoming"
  cp -a "$src" "$dst.incoming"
  rm -rf "${dst:?}"
  mv "$dst.incoming" "$dst"
  log "synced workspace/$tree from image"
done
mkdir -p "$ZC_WORKSPACE_DIR/state" "$ZC_WORKSPACE_DIR/receipts" "${SWEEP_STATE_DIR:=$ZC_WORKSPACE_DIR/state/sweeps}"
export SWEEP_STATE_DIR

# ── 7. Preflight ─────────────────────────────────────────────────
for bin in zeroclaw kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found on PATH"
done
if [ "$GH_ENABLED" = true ] && ! command -v gh >/dev/null 2>&1; then
  die "GH_TOKEN/GH_REPO set but gh is not installed"
fi
if ! kubectl auth can-i list pods --all-namespaces >/dev/null 2>&1; then
  log "WARNING: kubectl cannot list pods cluster-wide — check deploy/rbac.yaml."
fi

# ── 8. Start (or self-test and exit) ─────────────────────────────
# `--self-test` runs the checks CI needs against a fully rendered config and a
# freshly synced workspace, then exits. It never contacts a provider, a chat
# platform, or the cluster.
if [ "${1:-}" = "--self-test" ]; then
  log "self-test mode: validating rendered config, SOPs and skills"
  rc=0
  run_check() {
    log "--- $* ---"
    if "$@"; then log "PASS: $*"; else log "FAIL: $*"; rc=1; fi
  }
  run_check zeroclaw sop validate
  run_check zeroclaw skills audit k3s-admin
  run_check zeroclaw skills test k3s-admin
  # `doctor` inspects a daemon that is not running here, so a non-zero exit is
  # expected; surface its output without failing the build on it.
  log "--- zeroclaw doctor (informational) ---"
  zeroclaw doctor || log "note: doctor reported issues (no daemon running in self-test)"
  if [ "$rc" -eq 0 ]; then log "self-test passed"; else log "self-test FAILED"; fi
  exit "$rc"
fi

log "starting zeroclaw daemon ($(zeroclaw --version))"
exec zeroclaw daemon "$@"
