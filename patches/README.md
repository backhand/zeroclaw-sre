# Local patches

Applied to the pinned upstream ZeroClaw tag inside the `zcsource` build stage
(`docker build --build-arg ZC_SLACK=1`). **This is not a fork.**

A fork means tracking all of upstream forever and re-deciding, on every release,
what a merge did. A patch tracks only what we changed, and `git apply` failing
on a version bump is the signal you want: it says *this code moved, go look*,
rather than silently merging around it.

Every patch here should also be an upstream pull request. Delete it once merged.

| Patch | What it does | Why |
|---|---|---|
| `0001-slack-resolve-approval-prompt.patch` | After an approval button is clicked, rewrite the prompt with `chat.update` and `blocks: []` | Upstream delivers the decision and leaves the message untouched, so an answered request looks identical to an unanswered one and invites a second click |
| `0002-slack-thread-approval-prompt.patch` | Post the approval prompt into the thread the request is being handled in | Upstream posts it to the channel root, so approvals pile up detached from the question that caused them — burying the channel and leaving the approver no context |

Patches are applied in filename order and each is written against the result of
the previous one. Regenerate them in the same order.

## Refreshing a patch after a version bump

```bash
git clone --depth 1 --branch <new-tag> https://github.com/zeroclaw-labs/zeroclaw.git /tmp/zc
cd /tmp/zc
git apply --3way ../path/to/patches/0001-*.patch   # resolve any conflict
git diff > ../path/to/patches/0001-slack-resolve-approval-prompt.patch
```

Then rebuild with `ZC_SLACK=1`; a failed `git apply` fails the build loudly.

## Note on `blocks: []`

`chat.update` keeps a message's existing blocks when only `text` is supplied.
Omitting `blocks: []` would update the text and leave the buttons exactly where
they were — which is the bug, not the fix.
