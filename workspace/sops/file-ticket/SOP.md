# file-ticket

One issue per problem, forever, in the repo that owns the workload.

Two lookups make this procedure safe: step 1 decides *where* the issue goes,
step 3 decides *whether* it is new. Both are exact-match questions with scripted
answers — neither is a judgement call.

Writes to GitHub, not to the cluster.

## Steps

1. **Resolve the repo** — Require `$GH_TOKEN`; without a credential nothing can be filed, so say so in one line and stop. `$GH_REPO` being unset is *not* a reason to stop — it is only the last-resort default. Run `sh "$ZC_WORKSPACE_DIR/skills/k3s-admin/bin/repo-map.sh" resolve <namespace> <workload>`, which checks the workload's `sre.zeroclaw/github-repo` annotation, its namespace's annotation, the exact entry in the repo map, the namespace wildcard, then `$GH_REPO`. Non-empty output is the answer — use it and go to step 3.
   - tools: shell

2. **Ask, once, when it is unknown** — Empty output means nobody has ever said where this workload's issues belong. Use `ask_user` to ask in chat, naming the workload and quoting the finding in one line, e.g. *"prod/api-gateway is CrashLoopBackOff for the 3rd sweep. Which GitHub repo should I file this in? (owner/repo, or 'skip')"*. Then:
   - an `owner/repo` answer → record it with `repo-map.sh record <namespace> <workload> <owner/repo>`, and continue;
   - `skip` → post the finding to chat and stop, without filing;
   - no answer before the approval timeout → treat it as `skip`.
   Never guess a repo, never fall back to one that "looks close". A ticket in the wrong repo is worse than no ticket.
   - tools: ask_user, shell

3. **Search for an existing issue** — Search open issues labelled `zeroclaw-sre` in the resolved repo for the fingerprint:
   `gh issue list --repo "<repo>" --label zeroclaw-sre --state open --search "<fingerprint>" --json number,title,url,body`.
   Match on the fingerprint appearing in the title or in the `fingerprint:` line of the body — never on prose similarity. Also check memory for a stored issue URL under `sweep:<fingerprint>`.
   - tools: shell, memory_recall

4. **Comment when it already exists** — If an open issue matches, add one comment with the new evidence (last-seen timestamp, current restart count, the latest log signature) and stop. Do not re-title, do not re-open, do not file a second issue. Store the issue URL under `sweep:<fingerprint>` if it was not already there.
   - tools: shell, memory_store

5. **Otherwise open one** — Title: `[k3s] <namespace>/<workload>: <reason>`. Body must carry, in this order: a `fingerprint: <fingerprint>` line (this is what step 3 searches for), first-seen and last-seen timestamps, consecutive-sweep count, the owning workload and image, the last 20 log lines in a fenced block, the relevant events, and the exact kubectl commands that produced the evidence. Label it `zeroclaw-sre`.
   `gh issue create --repo "<repo>" --label zeroclaw-sre --title "..." --body-file -`
   - tools: shell

6. **Link it back** — Store the issue URL under `sweep:<fingerprint>` so later sweeps annotate the digest with `(issue #N)` instead of filing again, and post the URL to chat in one line naming the repo it went to.
   - tools: memory_store, send_via
