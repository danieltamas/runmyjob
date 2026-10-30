# Agents on boxes (proposal, 2026-10-30)

Status: proposal. Nothing here is built. It is gated on a measurement (see "Go / no-go").

## What it is

An agent run (`claude -p`, `codex exec`, any harness with a headless mode) is a job like a build: RMJ syncs the checkout
to a box, runs the harness in a hardened container, streams the log, and brings the result back to the Mac as a patch.
Bton (or any caller) asks RMJ instead of spawning the agent locally:

    rmj agent run --harness claude --worktree <path> [--rule <name>] -- "<prompt>"

Complete when: an agent task started on the Mac runs on a box, the Mac holds the only copy of the credentials, and the
result is a reviewable branch in the Mac worktree.

## Graceful and detected (same rules as builds)

> Status 2026-10-30: shipped as U14 for Claude Code and Codex (`--harness`), as ordinary rules on `command: ["claude"]`
> or `["codex"]` rather than a new rule kind. Egress allowlist (an internal docker network and one filtering proxy) and
> separate agent slots (`agent_slots`, default 2 per destination) are in. See docs/ARCHITECTURE.md, "Agent runs".

- Opt-in by a rule of the new kind `agent` (harness, boxes, image, cpus, memory, egress). No rule, no box, tailnet down,
  box without free agent slots, image missing, no fresh access token: the agent runs locally, and the ledger
  says why. Nothing is ever routed that cannot be served.
- The destination probe gains an `agents` section: harness images present, free agent slots, memory headroom, GPU
  present (optional). The card shows it; Setup builds the images (`rx-claude`, `rx-codex`; any image works).
- Tenants stay a hard deny: a company's repo never reaches another company's box, for agents too.

## Credentials: the same login, copied per run

The agent runs exactly as it would on the Mac, with the same subscription. No proxy and no credential swapping.
The Mac stays the only place that refreshes:

1. Before a run, RMJ makes sure the Mac's access token is fresh (it runs the harness's own refresh on the Mac).
2. It copies only the short-lived access token into the container (an env var or a tmpfs file, mode 600, never an image
   layer, never the box's disk, never the ledger or a log). The refresh token never leaves the Mac, so the box cannot
   rotate it and invalidate the Mac's copy.
3. The container is removed when the run ends, which removes the token.

Cost and limits: a run longer than the access token's lifetime fails at expiry and RMJ resumes it with a fresh token
(session resume), or the rule sets a maximum run length. A leaked access token is usable until it expires, so the
egress allowlist and the short lifetime are the controls, not secrecy.
Alternative for long runs: `claude setup-token` yields a long-lived token (`CLAUDE_CODE_OAUTH_TOKEN`) for the same
subscription; it is a larger blast radius if leaked, so it is opt-in per rule.
Unverified, the spike answers: the exact credential files and env vars Claude and Codex read, the access token's
lifetime, and whether a harness started with only an access token (no refresh token) runs cleanly to expiry.

## Security tightening (what the box adds)

- The agent cannot read the Mac: no ssh keys, Keychain, other repos, browser sessions, shell history.
- The synced tree is git-visible files only (RMJ already excludes ignored files such as `.env`).
- Container hardening as for builds (no capabilities, no new privileges, pid limit, box user), plus an egress allowlist:
  the vendor API, package registries and git hosts the rule names; everything else dropped.
- The result comes back as a git bundle or patch applied to a new branch on the Mac; the agent never has write access to
  the Mac checkout or push credentials. Bton reviews the branch.
- One container per run (isolation between concurrent agents), one image per harness, shared read-only caches.

## Sizing

Measured on `ai-gamerina-eu` on 2026-10-30: 24 cores, 52 GB RAM, about 34 GB available, load 4.3 with 22 containers
running. Default per agent: 2 CPUs, 4 GB, burst to the rule's limit; 6 concurrent agents reserve 12 CPUs and 24 GB, which
fits. Agent slots are counted apart from build slots so agents cannot starve CI gates. `cpus`, `memory` and the slot
count are per-rule settings. A 4 GB default is a guess: one `claude` was measured at several GB resident on the Mac, so
the spike records the real peak.

## GPU

Claude and Codex run their models at the vendor: a GPU on the box does not speed them up. It matters only for a harness
that runs a local model (ollama, opencode) or tasks that need CUDA. Offered as a rule option `gpu: true` (`--gpus all`),
detected by the probe, off by default. `ai-gamerina-eu` registers an `nvidia` Docker runtime but `nvidia-smi` is not on
the host, so a GPU there is unconfirmed. Not part of the first cut.

## What does not move

Work that needs macOS stays on the Mac: Swift packages importing AppKit or SwiftUI, Xcode, local browsers. The agent
itself can run on the box while such a command runs back on the Mac only if a later unit adds a callback; the first cut
does not. Interactive sessions are out of scope.

## Go / no-go: measured, not argued

A snapshot of this Mac on 2026-10-30 (10 cores, load average 31 to 34): the biggest CPU users were the SwiftPM test
helper (130 to 230 percent), a Virtualization VM (about 90 to 100 percent), Avast and Xprotect scanning (30 to 70
percent), and the `claude` processes at 30 to 45 percent in total. The agents' own CPU is small; the load is their
Swift builds, which cannot leave the Mac. So offloading pays only for work that runs on Linux (Rust, Node, Python, Go
repos). The spike must show that, or the feature does not ship.

Spike (one unit): `claude -p` and `codex exec` in a hardened container on `ai-gamerina-eu`, access token copied per run, one Rust or
Node repo, patch returned.

Measured by (same task, 3 runs each, local versus box, then 6 concurrent agents on the box):
- Mac CPU attributable to the agent task (sum of the agent's process tree and its children): box run under 15 percent of
  the local run.
- Wall-clock of the task on the box no more than the local one.
- Box with 6 concurrent agents: load stays under 20, no OOM, CI gate jobs on the same box not slowed by more than 20
  percent.
- No token persists on the box after the run: `docker inspect`, the box disk and logs searched for the token string find nothing once the container is gone; the refresh token is never on the box.
  token string finds nothing.

## Acceptance (once built)

- No agent rule, or the box without free agent slots: the task runs locally and the ledger names the reason (test).
- A `globex` repo is never routed to an `acme` box for an agent run (test).
- Egress outside the allowlist fails from inside the container (live test on a box).
- The patch applies to a fresh branch; a dirty Mac worktree is never overwritten (test).
- A killed Mac connection leaves no container running after the rule's timeout (test).

## Open questions

1. Does each harness work behind a base URL proxy with its subscription login (Claude, Codex)? The spike answers it.
2. Which MCP servers, hooks and skills the agent needs on the box, and how a reduced `~/.claude` is shipped per run.
3. How Bton passes a session and resumes it (a persistent per-repo volume on the box is the likely answer).

## Spike result (2026-10-30)

Task: "summarize this repo in 8 lines" (rapidcheck.ro, 98 files, Bun/TypeScript), `claude -p` with the same tool allowlist,
read-only. Local = this Mac with its normal plugins, hooks and MCP servers; lean = `--strict-mcp-config
--setting-sources project`; box = hardened `rx-claude` container on `ai-gamerina-eu` (cap-drop ALL, no-new-privileges,
2 CPUs, 4 GB, uid 1000, tmpfs /tmp) with the tree rsynced in and only the access token sent over ssh stdin. Mac CPU is
user+sys of the whole process tree (`time -l`), so it includes ssh, rsync and the Keychain read on the box path.

| Run | Wall | Mac CPU |
|---|---|---|
| local, 3 runs | 18 to 33 s | 9.1 to 10.1 s |
| local lean, 2 runs | 14 to 15 s | 3.3 s |
| box, 3 runs | 13 to 20 s | 0.23 to 0.24 s |
| 6 concurrent local | 33 s for the batch | 66.3 s total |
| 6 concurrent box | 27 s for the batch | 1.55 s total |

Same answer from both. Box CPU on the Mac is 2 percent of the local run (7 percent of the lean one) and wall time is
equal or better. Auth: the subscription worked with an access token only (no refresh token on the box); a credentials
file claiming an expired `expiresAt` still ran, so the client does not refuse locally and failure comes from the server at
real expiry. No copy of the token was found in the box's work, spike and shm directories after the runs, and no container
was left. Caveats: a read-only task; the build and test commands an agent runs are already routed by `rmj guard`, so the
gain here is the harness itself, which is what this measures. Not measured: a run past the real token expiry, Codex,
edits returning as a patch, the box's own load per agent (it stayed at 5 to 7 in the first six-way test).

## What to cache on the box

1. The harness in the image (`rx-claude`, CLI preinstalled): measured, removes about 45 s of npm install per run; the
   image builds in about 40 s.
2. The synced tree, per repo, kept between runs: rsync then sends only the delta (RMJ already does this for builds).
3. Dependencies and build output (node_modules, target, uv and go caches) in per-repo, per-tenant volumes, so an agent that
   runs tests starts warm. Never shared across tenants (cache poisoning).
4. The git baseline: ship the history once as a bundle, then only new commits, so the agent has `git diff` and the result
   comes back as a diff against a known commit.
5. The agent session directory per repo (resume a task later). Costs privacy: transcripts persist on the box; opt-in.
6. A derived image per repo keyed on the lockfile hash, when installs are slow.
Not worth caching: model answers (the vendor already caches the prompt prefix, wherever the harness runs), and warm idle
containers (a container starts in well under a second).

## Git model (decided 2026-10-30: files only)

The box gets the synced working files and no `.git`. RMJ keeps a manifest of what it sent (path and hash) and, when the
agent finishes, compares the container's tree with it and builds a patch. The patch is applied on the Mac to a new branch
`rmj/agent/<id>` created from the worktree's HEAD, in a throwaway clone first (`git apply --check`, size cap, no
symlink, `.gitmodules`, hook or `.git` paths); the worktree itself is never written. The agent has no git history on the
box: `git log`, `blame` and `diff` against HEAD are unavailable to it, and it cannot commit. Revisit (ship a bundle of the
last commits) if agents turn out to need history.
