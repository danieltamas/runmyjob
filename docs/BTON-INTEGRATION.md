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
4. RESOLVED in U20 (`--json`, see "U20 contract" below). Was: machine-readable result. `rmj agent run` prints a log, not JSON. Bton needs the job id and the branch: RMJ work:
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

### Bton findings (2026-11-01, from the Bton code at v0.23.1 plus the `hats` branch (shipped in Bton 0.24.0))

Claims confirmed:

- Bton starts Claude as `claude -p {prompt} --session-id {session} --permission-mode acceptEdits` (`Config.swift`, the
  default template), then `AgentHardening.hardened` adds `--setting-sources`, `--settings` (the sandbox locked on, with
  the helper tools allowed), `--append-system-prompt` (the hat's playbook, the base branch's CLAUDE.md, the graph line,
  the helper instructions), `--disallowedTools` (the gh writes that skip the merge gate, and for the decider and triager
  every gh and git write), `--mcp-config` when the job has helpers, `--model` and the effort flag (`AgentHardening.swift`,
  `Dispatch.swift` `DispatchPlanner.argv`).
- `maxAgents` is Bton's own limit (`BtonConfig.maxAgents`, 0 to 16, default 2); the second reviewer runs beside the first
  in the same worktree with its own session.
- The agent's result is the plain final message that `claude -p` prints on stdout, written to `~/.bton/jobs/<id>.out`
  and parsed by `DispatchPlanner.reviewComment(fromFinalMessage:headings:head:)`: first line a review heading naming the
  head, then the table. The live view reads the session transcript under `~/.claude/projects/<worktree>/<session>.jsonl`.
- Detection as rule 1 describes works today: `rmj route -- claude` run in `~/Sites/bton` answers `ai-gamerina-eu` through
  the rule "agent runs to the claude image".

Gaps found, beyond 1 to 5 above. Each is RMJ work or a decision; Bton builds nothing around them:

6. **RESOLVED in U20 (`--attach`).** Was: attachments do not reach the box. Bton puts what it read for the agent (pr-evidence.md, the issue thread, the
   feature context) in a scratch directory outside the tree (`$TMPDIR/bton-<job>`, `DispatcherOutcomes.swift`) and the
   prompt says to read it there. `TreeSync` sends the worktree only. Request: `--attach <dir>` mounted read-only in the
   container at the same path, or a documented path Bton writes to (`/work/.bton-scratch`) that the sync carries and the
   result import ignores.
7. **RESOLVED in U20 by 6: the caller attaches the diff as a file (the bundle is not built).** Was: no diff on the box. The git model is files only; the review playbook's first step is the PR diff and pr-evidence.md
   holds the PR's metadata and discussion, not its diff. Request: either ship `base..head` as a bundle (the doc's own
   "revisit"), or state that the caller attaches the diff as a file (then 6 covers it). Bton's preference: the bundle,
   since the fix and resolve moves need history too and a diff file reads nothing but the review.
8. **RESOLVED in U20 (`--json` with `final`).** Was: the result's shape. RMJ fixes `--output-format stream-json --verbose`; Bton reads a plain final message. This is
   gap 4 made concrete: `--json` on the last line with `job`, `location`, `branch`, `exit` and `final` (the assistant's
   last text), or RMJ writes the final message to a file Bton names.
9. **System prompt RESOLVED in U20 (`--append-system-prompt-file`); denied tools and settings stay out.** Was: no passthrough. `AgentTask.argv` takes `--allowedTools`, `--model`
   and the session only. On a box the playbook and the team's CLAUDE.md would have to travel inside the prompt (Bton
   does that for codex already: `playbook + "Your task:" + prompt`), the container replaces the sandbox lock, and the
   gh and git denials are moot without a login. Decision for RMJ: accept the prompt form, or add
   `--append-system-prompt-file <path>` so the two stay apart as they are on the Mac.
10. **DEFERRED.** The graph and the memory do not travel. `graphify-out` and `memory` are links hidden by `info/exclude`, so the
    sync leaves them out: a box run reads the tree cold and the graph-first steps in every hat's playbook are void there.
    Request: a per-repo volume RMJ fills from the Mac's `~/.bton/graphs/<repo>` before the run, or accept the cold run and
    say so in the job (Bton would drop the graph line from the prompt for a box run).
11. **DEFERRED.** The live view. Bton's job page follows the transcript under `~/.claude/projects` on the Mac; on a box it lives
    in `~/rx/.sessions/<key>` (U19). Bton can show the box's name on the row from `rmj jobs --json`, not the session.
    Request, later: `rmj agent log --follow <job>` or the transcript streamed to the Mac.
12. **RESOLVED (rule order in `~/.rmj/rules.json`, 2026-11-01).** Lexito routes `claude` to the gate profile, not the claude image.** `rmj route -- claude` in
    `~/Sites/lexito.ro/lexito.ro` matches "lexito gate image with its dev pair" (profile `lexito.ro`, the repo rule) before
    "agent runs to the claude image". The acceptance names a tenant repo with a box; for lexito that would start the
    gate image with the harness absent. Fix in `~/.rmj/rules.json`: match the gate rule on its commands, or put the agent
    rule first.
13. **Stays local.** Helpers and the second reviewer. A job with helpers runs `bton ask-server` over `--mcp-config` on the Mac; a box
    cannot reach it, and the graph tool rides on the same server. A review with helpers, and the second reviewer (same
    worktree, same attachments), stay local until 6 and 10 are settled.

What is eligible once 6 to 9 are in: the single-shot review (Bton posts the comment, the agent edits nothing). The fix
and resolve moves push from the agent's own shell today; on a box they return a branch, and Bton would push it, which is
new Bton work after the review runs. The triager, the decider and the intake coder run under the owner's login with gh;
they stay local.

Spike that would settle 8 and the exit codes without a Bton change: from `~/Sites/bton` (tenant personal, routes to the
claude image), `rmj agent run --require-box -- "list the top-level directories of this repo in one line"`; it syncs the
tree and leaves a branch `rmj/agent/<id>`. Not run yet: it was not asked for, and it writes a branch into the Bton clone.

Bton work when the requests land, in this order: the setting (rule 5, per repo override), detection cached per repo
(rule 1), eligibility (rule 2, review only), the `rmj agent run --require-box` path with exit 3 as "local as before"
(rule 3), the row naming the box (rule 5), tests for each; then the fix and resolve moves from the returned branch.

### U20 contract (what Bton builds against; unreleased until the owner releases RMJ)

- `rmj agent run [--attach <dir>]... [--append-system-prompt-file <file>] [--json] --require-box ... -- "<prompt>"`.
- `--attach`: up to 4 absolute directories, characters `A-Za-z0-9._/+@=-`, no `..`, not under `/work /tmp /run /proc /sys /dev /etc /usr /bin /sbin /lib /opt /root /home`
  (the Mac path is the container path). A path under `$TMPDIR` (`/var/folders/.../T/bton-<job>`) is accepted. Total at most 50 MiB, else
  the run goes local ("attachment too large") or, with `--require-box`, exits 3. Read-only in the container; removed from the box when the job ends.
- `--append-system-prompt-file`: a regular UTF-8 file, 1 to 64 KiB, Claude only (`--harness codex` is a usage error).
- `--json`: the last line of stdout is one object `{"branch","exit","final","job","location"}`, printed on a line of its own, whenever a job was created.
  `branch` is `rmj/agent/<ulid>` or null; `location` is `local` or the destination; `final` is the answer or null.
  On a box `final` exists for Claude only (Codex has no result event there: null).
- `--require-box` that cannot be served: exit **3**, stderr `rmj: not run, a box was required: <reason>`, and with `--json` the object is still printed
  (`exit` 3, `final` null, `location` the destination it was routed to, `branch` null). Usage errors exit 2 and print no JSON; if the ledger
  cannot be opened, exit 3 without JSON.
