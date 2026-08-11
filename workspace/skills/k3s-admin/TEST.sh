# Offline validation for the k3s-admin skill.
#
# Format (parsed by `zeroclaw skills test`, NOT executed as a shell script):
#   <command> | <expected exit code> | <expected output pattern>
# The pattern is tried as a regex against stdout+stderr, then as a substring.
# An empty pattern means "any output". Commands run with cwd = this directory.
#
# Everything here must pass with no cluster, no network, and no credentials.

# ── Tools the playbook depends on ────────────────────────────────
command -v kubectl | 0 | kubectl
kubectl version --client=true | 0 | Client Version
command -v jq | 0 | jq

# ── SKILL.md front matter ────────────────────────────────────────
head -n 1 SKILL.md | 0 | ^---
grep -c "^name: k3s-admin$" SKILL.md | 0 | ^1
grep -c "^description: " SKILL.md | 0 | ^1
grep -c "^version: " SKILL.md | 0 | ^1
grep -c "^tags: " SKILL.md | 0 | ^1
awk "NR>1 && /^---$/ {print \"closed\"; exit}" SKILL.md | 0 | closed

# ── Contracts the SOPs and the digest format depend on ───────────
grep -qF "<namespace>/<workload>/<reason>" SKILL.md | 0 |
grep -qF "k3s sweep —" SKILL.md | 0 |
grep -qF "rightsizing proposal" SKILL.md | 0 |
grep -qF "sweep:<fingerprint>" SKILL.md | 0 |
grep -qF "A clean sweep posts nothing" SKILL.md | 0 |
grep -qF -- "--tail=50" SKILL.md | 0 |
grep -qF -- "--previous" SKILL.md | 0 |

# ── Hard rules must still be stated ──────────────────────────────
grep -qF "kubectl delete" SKILL.md | 0 |
grep -qF "kubectl scale" SKILL.md | 0 |
grep -qF "kubectl drain" SKILL.md | 0 |
grep -qF "resources\` block only" SKILL.md | 0 |

# ── The shipped jq program must compile and behave ───────────────
jq -f jq/unhealthy-pods.jq /dev/null | 0 |
sh tests/jq-fixture.sh crashloop | 0 | CrashLoopBackOff
sh tests/jq-fixture.sh oomkilled | 0 | OOMKilled
sh tests/jq-fixture.sh healthy | 0 | ^$
grep -qF "jq/unhealthy-pods.jq" SKILL.md | 0 |

# ── The repo-map helper ──────────────────────────────────────────
# Behaviour that must hold without a cluster: usage, and refusing anything that
# is not a bare owner/repo before it can reach `gh issue create`.
sh bin/repo-map.sh | 1 | usage:
sh bin/repo-map.sh resolve | 1 | resolve needs
sh bin/repo-map.sh record ns app | 1 | record needs
sh bin/repo-map.sh record ns app https://github.com/o/r | 1 | is not an owner/repo
sh bin/repo-map.sh record ns app "o/r;whoami" | 1 | is not an owner/repo
sh bin/repo-map.sh record ns app "o r" | 1 | is not an owner/repo
grep -qF repo-map.sh SKILL.md | 0 |
grep -qF "sre.zeroclaw/github-repo" SKILL.md | 0 |

# ── No credential-shaped literals committed in the skill ─────────
grep -Eqr "(xox[baprs]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,})" . | 1 |
