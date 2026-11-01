# Bton hands unattended agent runs to RMJ (spec for the Bton agent)

Status: spec, 2026-11-01. Written from RMJ's side (`docs/AGENTS-ON-BOXES.md`, `Sources/RMJCore/Run/AgentRunCommand.swift`,
`AgentTask.swift`, `docs/ARCHITECTURE.md` "Agent runs"); Bton's own code was only skimmed (`BtonCore/Config.swift`). Verify
the Bton-side claims against the code before building.

## Goal

When RMJ is installed and has a box for the repo, an unattended Bton agent run (review, fix, playbook move, schedule)
runs on that box instead of on the Mac, and its result comes back as a branch Bton can review. Anything RMJ cannot serve
runs exactly as today. Interactive sessions never move.

Complete when: with RMJ detected and a `claude` rule enabled, a Bton review run of a repo of a tenant that has a box
shows up in RMJ's Jobs list as running on that box, Mac CPU for it is near zero, and Bton shows its result; with RMJ
absent, disabled or refusing, the run is byte-for-byte what Bton does today.

## What RMJ gives (exists today, U14)

    rmj agent run [--harness claude|codex] [--to <destination>] [--timeout 30m] [--unattended]
                  [--allow "Tool,Tool"] [--require-box] -- "<prompt>"

- Run it with the repo checkout (the worktree Bton prepared) as the current directory. RMJ syncs that tree to the box,
  runs `claude -p <prompt> --output-format stream-json --verbose --permission-mode acceptEdits` in a hardened container,
  and records the result as git branch `rmj/agent/<job id>` parented on the HEAD at the start. The worktree, its index and
  HEAD are never written.
- Routing is the owner's rules file (`~/.rmj/rules.json`, rule with `match.command: ["claude"]`, image `rx-claude`).
  Tenant deny, tailnet check, agent slots (`agent_slots`, default 2 per box) and the local fallback are RMJ's.
- Without `--require-box`, any refusal (no rule, no box, tailnet down, image missing, login expiring, ledger unavailable)
  runs `claude -p` on the Mac, recorded with the reason. With `--require-box` the same refusals fail the run.
- Exit codes: 2 usage; 3 a box was required and none served it (reason on stderr); 4 the box result could not be imported
  as a branch; otherwise the harness's own exit code. The log streams to stdout as readable lines.
- Detect before running: `command -v rmj`, and `rmj route -- claude` reports where the command would go (box name or
  local with the reason) without running anything.

## Rules for Bton

1. Detect: `rmj` on PATH, and `rmj route -- claude` (run in the repo) names a box. Not detected, or local: do what Bton
   does today. Never block a run because RMJ is missing or slow; budget 3 s for detection and cache it per repo for 60 s.
2. Eligible runs only: unattended, headless (`claude -p`) runs whose useful output is files changed in the tree or text on
   stdout. Not eligible: interactive sessions, a run that must resume or share a Claude session (see gap 1), a run that
   must push, comment or merge itself (see gap 2), a run that needs a macOS-only tool (swift, xcodebuild, codesign).
3. Call `rmj agent run --require-box` and treat exit 3 as "run locally as before" (not as a failed run). Treat 4 as a
   failed run with RMJ's message. Use `--to` only if the user pinned a box for the repo in Bton.
4. Result: when `git branch --list 'rmj/agent/*'` has a new branch from this run, Bton reviews it like any agent
   branch and applies or pushes it from the Mac itself. The run's job id is in RMJ's Jobs list; Bton may link to it.
5. A setting in Bton, default on when RMJ is detected: "Run unattended agents on RMJ boxes". Per repo override. The row of
   a run that went to a box says which box (RMJ's `rmj jobs --json` has `location` and `destination`).
6. Concurrency: Bton's `maxAgents` and RMJ's `agent_slots` are separate limits; a box with no free slot falls back to the
   Mac, so Bton must not wait on RMJ.
7. Cancel: terminating the `rmj` process cancels the box run (RMJ removes the container and the staged login).

## Gaps (RMJ side or Bton side; decide before building)

1. RESOLVED in U19 (`--session-id`, `--resume`, per-repo transcripts on the box). Was: Bton passes `--session-id {session}` and resumes sessions; `rmj agent run` has no session option and each
   run is a fresh container (open question 3 in `docs/AGENTS-ON-BOXES.md`). Until RMJ adds `--session-id` and a per-repo
   persistent volume, only single-shot runs are eligible. RMJ work: `--session-id`, the volume, tests. Bton work: none until then.
2. Tools that act outside the tree. Bton's template allows `Bash(git:*)`, `Bash(gh:*)`. On a box there is no push
   credential and no `gh` login by design (the agent returns a branch; it never pushes). A run that must push or call
   GitHub stays local, or Bton does that step itself from the returned branch.
3. RESOLVED for the model in U19 (`--model`); effort has no equivalent. Was: RMJ fixes the harness argv (`AgentTask.argv`): Bton's `--allowedTools` list maps to `--allow`, its permission mode
   to `--unattended`/acceptEdits; model and effort flags have no equivalent. RMJ work if Bton needs them: `--model`.
4. Machine-readable result. `rmj agent run` prints a log, not JSON. Bton needs the job id and the branch: RMJ work:
   `--json` that prints `{"job": "<ulid>", "location": "...", "branch": "rmj/agent/<ulid>"|null, "exit": N}` on the last
   line. Until then Bton reads the newest `rmj jobs --json` row for the repo.
5. Repos Bton clones itself. RMJ routes by the repo's tenant (owner and repos in `rules.json`); a repo no tenant claims
   runs locally (RMJ's "Run remote" chip tags it). Bton should not tag repos itself.

## Acceptance (observed, not mocked)

- RMJ present, rule enabled, box online, repo of that tenant: a Bton review run appears in `rmj jobs --json` with a
  `destination` and the branch `rmj/agent/<id>` exists in the repo.
- RMJ absent (PATH without `rmj`), or `rmj route` says local: the run is today's, and Bton's tests for it still pass.
- Box offline during the run start: exit 3, Bton runs it locally, one run is recorded, not two.
- A repo of tenant `globex` never reaches an `acme` box (RMJ's test; Bton must not pass `--to` across tenants).
- Mac CPU for a box run is under 15 percent of the local run (spike measured 2 to 7 percent, `AGENTS-ON-BOXES.md`).

## Out of scope

Interactive sessions; moving a running session; any credential handling in Bton (RMJ reads the Mac's login and sends only
the access token); changing RMJ's rules from Bton.

## Hand-off

Bton agent: read this file and `docs/AGENTS-ON-BOXES.md`, confirm each Bton-side claim in the code, then build rules 1 to 7
behind the setting, starting with single-shot review runs. Report gaps 1, 3 and 4 back as RMJ requests; do not work
around them in Bton.
