# file-ticket

One issue per problem, forever. The search in step 2 is what stops this
procedure from turning a flapping pod into fifty issues.

Writes to GitHub, not to the cluster.

## Steps

1. **Preconditions** — Require a fingerprint (`<namespace>/<workload>/<reason>`). If `$GH_REPO` or `$GH_TOKEN` is unset, post one line to chat saying ticket filing is disabled and stop — do not fail loudly every sweep.
   - tools: shell

2. **Search for an existing issue** — Search open issues labelled `zeroclaw-sre` in `$GH_REPO` for the fingerprint:
   `gh issue list --repo "$GH_REPO" --label zeroclaw-sre --state open --search "<fingerprint>" --json number,title,url,body`.
   Match on the fingerprint appearing in the title or in the `fingerprint:` line of the body — never on prose similarity. Also check memory for a stored issue URL under `sweep:<fingerprint>`.
   - tools: shell, memory_recall

3. **Comment when it already exists** — If an open issue matches, add one comment with the new evidence (last-seen timestamp, current restart count, the latest log signature) and stop. Do not re-title, do not re-open, do not file a second issue. Store the issue URL under `sweep:<fingerprint>` if it was not already there.
   - tools: shell, memory_store

4. **Otherwise open one** — Title: `[k3s] <namespace>/<workload>: <reason>`. Body must carry, in this order: a `fingerprint: <fingerprint>` line (this is what step 2 searches for), first-seen and last-seen timestamps, consecutive-sweep count, the owning workload and image, the last 20 log lines in a fenced block, the relevant events, and the exact kubectl commands that produced the evidence. Label it `zeroclaw-sre`.
   `gh issue create --repo "$GH_REPO" --label zeroclaw-sre --title "..." --body-file -`
   - tools: shell

5. **Link it back** — Store the issue URL under `sweep:<fingerprint>` so later sweeps annotate the digest with `(issue #N)` instead of filing again, and post the URL to chat in one line.
   - tools: memory_store, send_via
