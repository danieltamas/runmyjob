# RMJ plan

Status: spec written 2026-10-27 and revised the same day after a Codex review (60 findings,
`docs/reviews/2026-10-27-codex-spec.md`; what was folded in and what was declined is in LOG.md).
Nothing built. The reference implementation it absorbs (`rx`, the pre-bash guard, the
fleet-runners stack) works today in `~/agent-os` and on `ai-eu-1`. Open decisions (bottom
of this file) are asked when the unit that needs them starts.

## What it is

RMJ (Run My Job) is an open source macOS menu bar app (MIT) and a CLI (`rmj`) for one person with
several coding agents and a small fleet of Linux boxes on a tailnet. It answers, in one panel: where
do my builds, test suites and CI jobs run, what is running right now and how far is it, what ran
today and how long it took, what failed and where is its log, and which box takes what. It routes
each job by rules the owner writes, reaches every box over Tailscale with nothing installed there,
keeps a local ledger with exact timings, keeps logs for 30 days on both sides with automatic
pruning, reruns a failed job, cancels a running one, and lets an outside agent inspect failures
through a read-only MCP server and the CLI.

It is the third app of a family: Bton (agents on pull requests), MacMax (why is my Mac slow), RMJ
(where do my jobs run). Same principles: menu bar panel, Settings, About with Update, one-line
installer, Homebrew cask, README with real screenshots, no third-party packages, no telemetry.

Two kinds of routing, kept apart in every document and screen:
- **rx jobs** (a command an agent or the owner runs in a checkout): RMJ chooses the destination
  from `rules.json` and runs the command there. This is the routing RMJ owns.
- **GitHub jobs** (a workflow job): GitHub chooses the runner from the workflow's `runs-on`
  labels. RMJ shows which destination hosts the runner for those labels, watches, reruns, and
  manages the runner containers on the destination. It does not route these; it shows a mismatch
  when a workflow asks for labels no destination serves.

Companion specs (each is part of this plan; where they disagree, this file wins):

| File | Holds |
|------|-------|
| `docs/ROUTING.md` | Destinations, tenants, the rules file, the job model, reachability over Tailscale, the rx contract (argv, launch record, locks, cancellation), logs and retention |
| `docs/ARCHITECTURE.md` | Targets, pollers, store (cross-process), the run engine, the GitHub side, CLI |
| `docs/DESIGN.md` | The UI standard: panel, tabs, tokens, every view's rules |
| `docs/AGENT-API.md` | `rmj mcp` tools with their schemas, CLI JSON output, the boundary |
| `SECURITY.md` | Threat model and trust boundaries |
| MacMax `docs/LESSONS.md`, `docs/RELEASE.md`, `docs/SCREENSHOTS.md` | Reused as is: working rhythm, plumbing, Settings and About rules, release ceremony, screenshot rendering. U12 copies RELEASE.md and SCREENSHOTS.md with the names changed |

## Complete when

On this Mac, with the tailnet up: `rmj run -- cargo check` in the axon checkout runs on
`ai-eu-1`; the panel shows it running with a live elapsed time, the age of its last output
line and the log tail; after it ends the Jobs tab (30 days, searchable) and `rmj jobs --json` carry the row with
queued, sync, start and end timestamps (the container's own, with provenance), the exit code, the
destination, the rule, and the log kept locally. A atlas pull request's `check` job appears in
the same Jobs list while it runs on the self-hosted runner, with its current step, its queue wait
and what was observed about the runners, and can be rerun from the panel. The Destinations tab
shows the Acme box with reachability, load, rx slots, runners (version, online, busy, stale
with prune) and images. With the tailnet fixture `stopped`, the same `rmj run` runs locally and the
row says location `local`, reason `tailnet down`, with its own exit code and log. `rmj hooks status`
reports the guard installed for every harness on this Mac that has a pre-command hook and names
the ones it cannot cover. v0.1.0 is published on github.com/danieltamas/runmyjob with a
reproducible zip and `SHA256SUMS`. The Globex destination (s1) is added through the app's flow when
the owner starts Globex; v0.1.0 ships with that scenario tested against fixtures and recorded as
pending in the release notes (decision D6).

## Measured by

`scripts/acceptance.sh` exits 0. It runs, in order, failing on the first error:
1. `scripts/check.sh` (build, full test suite, file-size and ASCII lint).
2. The live suite (`RMJ_LIVE=1`): tailnet status parsed from the real `tailscale`, a probe of
   `ai-eu-1`, `rmj run --to ai-eu-1 -- true` (an explicit destination, since no
   shipped rule routes `true`), the ledger row with location `ai-eu-1`, the pulled `.meta`
   and log.
3. The fault suite, all with fixtures (`RMJ_TAILSCALE_FIXTURE=<path>`, `RMJ_BOX_FIXTURE=<path>`):
   tailnet stopped; peer offline; address outside the tailnet; ssh timeout; launch record
   `start-failed`; a remote command exiting 125 after starting (no local rerun); a client killed
   mid-run then reconciled; a box "reboot" (container gone, partial log present); two runs of the
   same worktree in a row (second waits for the lock); a `globex` repo against the Acme
   destination (denied); a rules file with an error (everything local, error shown).
4. `scripts/perf.sh`: idle CPU of the app under 0.4 percent over 10 minutes with no job running,
   under 2 percent with one job streaming.
5. An MCP smoke test: `rmj mcp` over stdin answers `initialize`, `tools/list`, `destinations`,
   `jobs`, `failures` with valid JSON-RPC matching the schemas in AGENT-API.md, within 500 ms
   each, from the SQLite ledger.
6. `scripts/release.sh <version> --verify` on the release tag (byte-identical rebuild) and
   `RMJ_VERSION=<version> ./install.sh` installs the published release.

Plus one manual check recorded in the release notes: a failed job's log opened from the
notification.

## Non-goals (v1)

- A scheduler or a queue of its own. A job runs when an agent or the owner starts it, on the
  destination the rules pick. GitHub is the only queue, for GitHub jobs.
- Routing GitHub jobs. `runs-on` decides; RMJ shows the mapping and the mismatches.
- An agent, daemon, timer or service on any box. Boxes need ssh, docker and rsync. State on a box
  is files under `~/rx/` written by the run itself; pruning there happens when the Mac touches
  the box (every run, the app's daily pass, `rmj prune`), never unattended.
- Offloading Swift or anything that must run on macOS. Those stay local and appear in the ledger
  only if started through `rmj run`.
- Transactional capacity reservation across concurrent CLI invocations. Capacity is a best-effort
  count plus a memory budget per destination (U3); one owner, two boxes.
- Multi-user, teams, a hosted service, Windows or Linux clients.
- Any network call besides ssh and rsync to verified tailnet addresses, the GitHub API through
  `gh`, the update check, optional log streaming to the sinks the owner configures (docs/LOG-STREAMING.md), and the More apps list read from the registry
  (`raw.githubusercontent.com/danieltamas/registry`).

## Layout

Each unit is one session, one PR, acceptance tests by Codex before or alongside the code, a Codex
review of the diff, P0-P2 fixed and re-reviewed. Units on the same row of "depends on" can run in
parallel in separate worktrees. In the `/goal` lines, `$SCRATCH/review-out.md` is Codex's review of
the unit's final diff, re-run after the last fix; "prints 0" means no P0, P1 or P2 remains.

| Unit | What | Depends on | Touches |
|------|------|------------|---------|
| U0 | Skeleton from MacMax, scripts, process helper, Keychain check, theme, CI | none | Package, Support, scripts, Sources (3 targets), Tests, CI |
| U1 | Tailnet state and destination probe | U0 | Core Net, tests |
| U2 | Ledger store (SQLite, cross-process), retention, log archive and pull | U0 | Core Store, tests |
| U3 | Rules file, router, explain, capacity | U0 | Core Routing, tests |
| U4 | Run engine: `rmj run` (the rx port), sync, launch record, stream, cancel, reconcile, local fallback | U1, U2, U3 | Core Run, CLI, Support/box, tests |
| U5 | GitHub side: runs, jobs, attempts, runners, queue observation, rerun, job logs | U2 | Core GitHub, tests |
| U6 | Destination operations: add, runner stack deploy, start/stop/drain, registrations, images, PAT, heartbeat | U1, U5 | Core Ops, Support/runner-stack, tests |
| U7 | Panel UI: Jobs, Destinations, Routing; menu bar icon; Settings | U4, U5, U6 | App target, DemoShots |
| U8 | History | U2, U7 | App target |
| U9 | Hook installation for Claude Code, Codex, OpenCode, Hermes; shims where no hook exists | U3, U4 | Core Hooks, Support/hooks, CLI, tests |
| U10 | CLI JSON and `rmj mcp` (read-only) | U2, U3, U5 | CLI target, Core Agent, tests |
| U11 | Updater, About, login item, notifications | U0, U7 | App target, Core Release |
| U12 | Release: signing, installer, README media, first public release | U0-U11 | scripts, README, docs, SECURITY |
| U13 | s1 as the first destination added through the app (Globex; execution after the owner's go) | U6, U7 | docs, LOG |
| U14 | Agent runs: `rmj agent run` (Claude Code in a container on a box, access token only, result as a branch) | U4 | Core Run, CLI, Support/box, tests |
| U16 | Box streams: one long-lived ssh session per box replaces the app's probe timer; silence turns a box grey | U7 | Core Net, Panel, App PanelModel, tests |
| U17 | Tenants: colour and pattern per tenant, Tenants pane, box order inside a group, tag a local job's repo from the job list | U2, U7 | Core Routing, Panel, App Settings and Jobs, tests |
| U18 | Live sensors: 2 s frames while the panel is open, pushed to the UI | U16 | Core Net, App PanelModel, tests |
| U19 | Agent runs: --model, --session-id and --resume with a per-repo session directory on the box | U14 | Core Run, box script, tests |
| U20 | Agent runs: --attach, --append-system-prompt-file, --json result | U19 | Core Run, box script, tests |

## Units

### U0. Skeleton
- SwiftPM, Swift 6 language mode, macOS 14 deployment target, no third-party packages. Targets
  `RMJCore` (no SwiftUI or AppKit imports), `RMJ` (SwiftUI app), `RMJCLI` (installed as `rmj`),
  `RMJCoreTests`. Bundle id `ro.danieltamas.rmj`, `LSUIElement`.
- Copy and rename from MacMax's current `main`: `ProcessRunner` and `Executables`, `Theme`,
  `Looks`, `Components`, the Settings parts, `LoginItem`, `UpdateController`, `MacMaxHome` (as
  `RMJHome`), `bundle.sh`, `install-from-source.sh`, `make-signing-identity.sh`,
  `render-icons.sh`, `check.sh`, the CI workflow. Rename every `MacMax`, `macmax`, `MACMAX_`
  literal. Drop MacMax's collectors, rules and network code.
- `RMJHome`: `~/.rmj` (or `$RMJ_HOME`), mode 0700 even when it exists.
- Keychain: a `Keychain` helper and an installed-app test (`scripts/keychain-check.sh`) that
  proves the ad hoc signed app and the CLI read the same item (`rmj.test`) across an update, and
  documents the prompt macOS shows when they cannot. If they cannot, the CLI reads PATs through
  the app over an XPC-free path: a short-lived file handed over by the app (decision D7).
- `scripts/check.sh`: build with an explicit scratch path, run the suite, fail on any Swift file
  over 500 lines, fail on non-ASCII punctuation in `README.md`, `docs/`, `Sources/` user-facing
  strings.
- Icons (decision D4, done): `Brand/icon-app.svg`, `Brand/icon-menubar.svg`, rendered by
  `scripts/render-icons.sh`.
- GitHub Actions: build and test on every PR, actions pinned by SHA, Xcode pinned.

Acceptance:
- `swift build` produces three products; `RMJCore` imports neither SwiftUI nor AppKit.
- `ProcessRunner`: a child that ignores SIGTERM is killed by the group KILL after the timeout; a
  grandchild holding the pipe does not hang the read; stdout and stderr are captured separately;
  arguments are passed as an array, never through a shell.
- `RMJHome` creates `~/.rmj` with mode 0700 and fixes a wider mode.
- `scripts/check.sh` fails on a 501-line file and on an em dash in a user-facing string.
- `scripts/keychain-check.sh` passes on this Mac with the installed build (recorded in LOG.md).

/goal: `scripts/check.sh` exits 0, `scripts/keychain-check.sh` passes, and `$SCRATCH/review-out.md`
prints 0 P0-P2.

### U1. Tailnet state and destination probe
- `TailnetState` from `tailscale status --json` (the CLI in Tailscale.app or on PATH):
  `BackendState`, `Self.Online`, `CurrentTailnet.MagicDNSEnabled`, every peer's `ID`, `DNSName`,
  `HostName`, `TailscaleIPs`, `Online`, `LastSeen`, `KeyExpiry`, `Relay`. States: `running`,
  `stopped`, `needsLogin`, `noClient`, `unknown(reason)`. Polled every 10 s while the panel is open
  or a job runs, every 60 s otherwise, and at once on wake from sleep; cached with its age.
- A destination's peer is selected from that list by the stable `ID` stored when the destination
  was added (the name is for display; MagicDNS off, split DNS and renames do not matter). The
  address used is the peer's current `TailscaleIPs[0]`; a destination configured as a literal IP
  must be one of a peer's addresses. An expired key or a relayed (DERP) connection is shown, not
  blocked (DERP is still the tailnet).
- `DestinationProbe`: ssh to the verified address with the fixed argv in ROUTING.md (the alias
  only supplies the user and the host-key name), 5 s timeout, then `docker info`, `rsync
  --version`, expected images, `nproc`, free memory, 1-minute load, running containers with the
  `rx` and runner labels and their `docker stats` sample, `/proc/sys/kernel/random/boot_id` (to
  detect a reboot), and `date +%s%N` for the clock offset. Result is a `Reading` (ok,
  unavailable(reason), failed(reason)) with its timestamp; never a thrown error that stops the
  poller.
- `RMJ_TAILSCALE_FIXTURE=<path>` replaces the CLI output; fixtures under `Tests/Fixtures/tailnet/`
  (`running.json`, `stopped.json`, `needs-login.json`, `peer-offline.json`, `relayed.json`,
  `key-expired.json`, `magicdns-off.json`, `renamed-peer.json`).

Acceptance:
- `stopped.json` yields `stopped` and every destination offline without any ssh attempt (a spy
  counts).
- `peer-offline.json` yields `offline(peer offline, last seen <t>)`; `running.json` with ssh timing
  out yields `unreachable(ssh timeout)`; both reach the router as not available.
- `renamed-peer.json` (same `ID`, new `DNSName`) still resolves the destination; `magicdns-off.json`
  changes nothing; a literal IP not in any peer's addresses is `rejected: not a tailnet address`
  before any connection.
- The ssh argv contains `-o HostName=<verified ip>`, `-o HostKeyAlias=<alias>`, `-o ProxyCommand=none`,
  `-o ProxyJump=none`, `-o ControlMaster=auto`, `-o ControlPath=<RMJ's own 0700 directory>/%C`, `-o ControlPersist=10m`, `-o BatchMode=yes`,
  `-o ConnectTimeout=5`, `-o RequestTTY=no`, `-o StrictHostKeyChecking=yes`; rsync's `-e` carries
  the same.
- A probe whose `boot_id` differs from the last one marks the destination `rebooted since <t>`.

/goal: the U1 tests pass, `RMJ_LIVE=1` probes `ai-eu-1` as `online` with docker and rsync
ok, and `$SCRATCH/review-out.md` prints 0 P0-P2.

### U2. Ledger store, retention, log archive
- SQLite at `~/.rmj/rmj.sqlite`, WAL, `busy_timeout` 5 s, every state change one transaction with
  a precondition on the previous state (`UPDATE ... WHERE state = ?`), `job.id` unique, a
  `schema_version` table with a migration lock row. The app and every `rmj` process are
  separate writers through the same code; the app watches the file (`DispatchSource`) and
  re-queries. Tables: `job`, `job_event`, `destination_sample` (7 days), `runner_registration`
  (first and last seen, status, busy), `log_archive` (job id, side, path, bytes, complete or
  truncated, pending or available or unavailable with reason).
- Timestamps are UTC with millisecond precision; each carries its provenance: `mac` (the Mac's
  clock), `box` (the container's `StartedAt`/`FinishedAt` from `.meta`), `github` (the API). The
  Mac also records a monotonic elapsed for every run it attended. Duration shown is the box pair
  when complete, else the Mac's monotonic elapsed, else `unknown`; the clock offset from the probe
  is stored with the row. Contradictory values (end before start) show `unknown`, never a
  negative.
- Log archive, both sides, every completed run: the box keeps `.log`, `.rc`, `.meta` 30 days from
  completion; the Mac pulls every completed rx run's log into `~/.rmj/logs/<job-id>.log` (failed
  and lost first, at once; the rest within the next reconcile), local runs write there directly,
  and a GitHub job's log is fetched with `gh run view --job <id> --log` on completion for failed
  jobs and on demand for others. A pull that cannot happen (Mac asleep, app closed, box offline)
  stays `pending` and is retried at every reconcile; a running log is never cached as final.
- Bounds: a single log is capped at 50 MB with a truncation marker at the cut; the local archive
  at 2 GB (oldest completed first); a full disk keeps the row and its outcome and marks the log
  `unavailable: disk full`. Known secrets (the Keychain PAT values) are redacted before any byte
  is written locally, across chunk boundaries.
- Retention: a job row and its files expire 30 days after its completion time; rows in `queued`,
  `syncing`, `running`, `lost`, or with a `pending` log are never expired; the pass runs on launch
  and daily and by `rmj prune`; files go first, the row last, so a crash leaves a row that points
  at a missing file (`unavailable: pruned`), never a file without a row.

Acceptance:
- Two processes writing the same job concurrently: the state machine never goes backwards (a
  `done` row ignores a late `running`), and the event order is by the event's own timestamp.
- A job completed 31 days ago and its local log are removed; one at 29 days is kept; a `lost` job
  from 40 days ago is kept and shown as needing reconcile.
- A 60 MB stream is stored as 50 MB plus the marker and the row says `truncated`.
- A fixture PAT value printed inside a log never reaches the file; a value split across two chunks
  is still redacted.
- A log pull attempted while the box fixture is offline stays `pending` and succeeds on the next
  reconcile with the box online.

/goal: the U2 tests pass and `$SCRATCH/review-out.md` prints 0 P0-P2.

### U3. Rules file, router, explain, capacity
- `~/.rmj/rules.json` (Codable, Foundation only; decision D8 replaced TOML) as specified in
  ROUTING.md: destinations, tenants with an explicit `repos` table, ordered rules, first match
  wins, local last, the tenant deny before the rules. Any error (parse, unknown key, reference to
  an unknown destination or image, duplicate names) means every job routes locally with
  `reason: rules invalid: <path> <message>` and the panel shows it. The app edits the file by
  re-reading, validating, writing a temp file and renaming; an external edit between read and
  write is detected (mtime and hash) and refused with the diff shown.
- Repository identity: the canonical `owner/name` from the origin URL (ssh or https, with or
  without `.git`, lower-cased), the worktree path, and a `dirty` flag. A repo whose owner appears
  in no tenant is `unclassified` and routes locally with that reason until the owner classifies it
  in Settings (never "personal" by default).
- Command matching: the first word and, for `cargo` and `just`, the first subcommand (`cargo
  build`, `cargo test`, `just check`); the shipped rules put the specific local `cargo build` rule
  before the general Cargo rule, and a test pins that order.
- Availability for routing: the latest probe at most 60 s old; older than that, `rmj run` probes
  once before dispatch. Capacity: the destination's running rx count (from that probe) below
  `max_jobs`, and the memory budget (`memory_budget` minus the limits of running rx containers
  and the runner caps) above the rule's `memory`; otherwise the chain moves on with the reason.
- `rmj route [--repo owner/name] [--path dir] -- <command>` prints the inputs it used (repo,
  tenant and how it was resolved, worktree, command words, files checked, tailnet state and age,
  each destination's probe age), then the chain line by line, the matched rule, every skipped
  destination with its reason, and the result; `--json` for agents. The `--to <destination>`
  override of `rmj run` bypasses the rules but never the tenant deny.

Acceptance:
- A `globex` repo never routes to a `acme` destination, including with `--to`; the explain says
  `denied: tenant globex on acme destination`.
- `git@github.com:Acme/Notes.git` and `https://github.com/acme/notes` are the same
  repo; an owner in no tenant routes `local: unclassified repo`.
- `cargo build` in a Cargo repo routes `local` by the shipped rules; `cargo test` routes to
  `ai-eu-1`; `cargo` alone matches neither.
- A probe older than 60 s triggers one re-probe before dispatch (a spy counts); a destination at
  `max_jobs` or over its memory budget is skipped with the reason.
- A rules file with an unknown key, or a rule naming an unknown destination, routes everything
  locally with the path and message; the previous valid file is not overwritten by the app.
- `RX_LOCAL=1` routes locally with `reason: forced`.

/goal: the U3 tests pass, `rmj route -- cargo test` in `~/Sites/axon` prints `ai-eu-1`
(tailnet up) and `$SCRATCH/review-out.md` prints 0 P0-P2.

### U4. Run engine
- `rmj run [--to dest] [--shell] -- <command...>` is the port of `~/agent-os/adapters/rx`. The
  job's ULID is allocated and written to the ledger (`queued`) before anything else; it names the
  remote side (`rx-<repo>-<ulid suffix>`, a container label `rmj.job=<ulid>`, the record files on
  the box), so a lost launch response is reconciled by the ULID, idempotently.
- Argv is preserved end to end: the command is shipped as a JSON array in `<name>.argv` and the
  container runs it with `exec` (no shell) through `rx-run.sh`; `--shell` runs one string through
  `bash -c` for intentional shell syntax, and the guard's rewrite uses `--shell` only when the
  intercepted command contains shell syntax. Local runs use the same two modes.
- Sync: the worktree's files that git sees, with `rsync --delete`, under a per-worktree lock on
  the box (`flock` on `<dir>.lock`) that the box-side waiter holds from the sync to the end of the
  container, so a second run of the same worktree waits (shown as `waiting for <job>`), and a
  repo-level lock where a rule asks for one (ledger). Sync time is recorded on its own.
- Launch record: `rx-run.sh` writes `<name>.launch` = `started <container id> <boot_id>` or
  `start-failed <reason>` before anything else. Local fallback after dispatch happens only on
  `start-failed` or when the launch record is absent and the probe proves no container with the
  job's label exists; an exit code of 125 from a started command is the command's.
- Streaming: the waiter writes `docker logs -f` to `<name>.log` from the start (not after the
  end), so a reboot or a lost client leaves the partial log; the client streams the same; the
  panel's tail reads the local copy the client writes.
- Cancellation: Ctrl-C in the client or Cancel in the panel sends a cancel (`docker rm -f` by
  label over ssh, best effort, then the waiter records `cancelled`); the app quitting or the
  client dying without a cancel leaves the job running (`detached`, still `running` in the
  ledger) and the next reconcile settles it. `rmj cancel <id>` for both locations.
- Reconcile, on every `rmj` invocation, app launch, wake from sleep and every 60 s while a job is
  `running` or `lost`: for each online destination, read the job's `.launch`, `.rc`, `.meta`,
  the container's presence and the `boot_id`; a container gone after a reboot without `.rc` is
  `lost: destination rebooted` with the partial log pulled. Three failed probes in a row during a
  run mark it `lost: destination unreachable` (U6 heartbeat), reversible when the box returns.
- Local runs record location `local` with the fallback reason, the same lifecycle and exit code,
  and a flag `environment: mac` so a passing suite that skipped Linux-only cases is shown as
  reduced verification in the row.
- The agent that started the run is recorded from the environment (`CLAUDE_CODE`, `CODEX_*`,
  `OPENCODE_*`, `HERMES_*`, else `terminal`), with the harness session id when present; the row
  also carries branch, short commit and `dirty`.
- `rx` in `~/agent-os` becomes a one-line alias of `rmj run` once U9 is done (decision D1).

Acceptance:
- With the tailnet fixture `stopped`, `rmj run -- false` exits 1, location `local`, reason
  `tailnet down`, state `failed`, log archived locally.
- A box fixture answering `start-failed` runs locally with `reason: container start failed`; a
  command that exits 125 after `started` is `failed` with exit 125 and never runs locally.
- The command `echo '$(whoami)' "a b"` runs literally on the box (argv mode) and prints the two
  arguments unchanged; with `--shell` the substitution happens.
- Two `rmj run` of the same worktree: the second's row shows `waiting for <first id>` and starts
  after the first ends; the sync never touches a directory whose lock is held.
- A client killed mid-run: the container finishes, `.rc`, `.meta` and the full `.log` exist on
  the box, no container remains, and the next `rmj jobs` shows the row settled with box timing.
- Box fixture "rebooted" (new `boot_id`, container absent, partial log): the row is `lost:
  destination rebooted`, the partial log is pulled and marked `truncated`.
- Cancel during a run: the container is gone within 10 s and the row is `cancelled`.
- The sync excludes `.git`, ignored build output and `node_modules`, includes tracked files a
  `.gitignore` pattern would hide, and never follows a symlink out of the checkout.

/goal: `RMJ_LIVE=1` suite green against `ai-eu-1`, `rmj run -- cargo check` in axon green
with a complete ledger row, and `$SCRATCH/review-out.md` prints 0 P0-P2.

### U5. GitHub side
- Watched set: every `owner/name` in the rules' `[repo]` table plus every repo of each listed org
  and owner (listed once an hour, paginated). With `gh auth token` per call (RMJ stores no token;
  the org runner calls use the Keychain PAT read-only), the poller reads workflow runs and jobs
  (paginated, `per_page=100`, back to 30 days on first run and after any downtime gap) with ETags.
  Interval 15 s for repos with something queued or running, 120 s after a run in the last day, 300 s otherwise; the panel's footer
  states both. A 403 rate limit stops polling until `X-RateLimit-Reset` and the panel says so.
- Per job attempt (run id, job id, `run_attempt`): GitHub's `status` and `conclusion` as given
  (`success`, `failure`, `cancelled`, `skipped`, `timed_out`, `action_required`, `neutral`), the
  job's own `created_at`, `started_at`, `completed_at`, its steps with the current step name and
  number, the runner name and labels. Destination connectivity never changes a GitHub job's
  state; a box that goes unreachable while GitHub still reports the job running shows both facts.
- Queue observation, not a verdict: for a queued job, the labels it asks for, the registrations
  matching them (online idle, online busy, offline idle, offline busy, with names) and when that
  was observed; a suspected cause only when exactly one explains it (stale registration, all
  busy, none online), else `unknown`. Dependency wait (`needs`) is shown separately when the run's
  other jobs were still running at the job's creation.
- Rerun: bound to the repo and run id (`gh run rerun <run id> -R owner/name [--failed]`), with
  `--failed` only when the run has failed jobs and the selected job is one of them; the new attempt
  links to its parent in the ledger.
- Mapping to destinations: a label set is served by a destination when one of its runner targets
  registers runners with those labels; a workflow whose labels no destination serves is shown as
  a mismatch on the Routing tab.

Acceptance:
- A fixture with a queued job, one `offline, busy=false` registration matching its labels and no
  online runner yields observation `0 online, 1 offline idle (<name>)` and suspected cause `stale
  registration`; with one online idle runner as well, the cause is `unknown`.
- A job with `conclusion: skipped` is a `skipped` row, never `failed`; a `timed_out` is `failed`
  with that conclusion.
- Rerun of a run with a failed job calls `gh run rerun <id> -R <repo> --failed`; of a cancelled
  run, `gh run rerun <id> -R <repo>`; argv, not a shell string.
- Pagination: a fixture with 250 runs in 30 days yields 250 rows; a 7-day gap in polling is
  backfilled on the next poll.
- The 403 handling stops requests until the reset time; the panel's footer shows it.

/goal: the U5 tests pass; with a real atlas rerun the Jobs list shows the job within 15 s of
queueing with its current step and its observation; `$SCRATCH/review-out.md` prints 0 P0-P2.

### U6. Destination operations
- Add destination (Settings > Destinations > Add): name, the tailnet peer picked from the live
  list (its `ID` is what is stored), ssh user and alias, tenant, roles, home, `max_jobs`,
  `memory_budget`. The flow probes (U1) and reports each check with a fix hint, then writes the
  destination into `rules.json`. Nothing is installed; `rsync` and `docker` missing are reported.
- Runner stack: `Support/runner-stack/` is the vendored copy of `~/agent-os/jobs/fleet-runners`.
  Deploy copies it to `<home>/infra/gh-runners` (rsync, same ssh argv), writes `.env` from the
  Keychain items (`rmj.pat.<target>`) atomically (temp file, no-follow, mode 600, rename), runs
  `docker compose build` and `up -d`, streams the output with the PAT values redacted. The remote
  `.env` is a documented copy of the credential: Settings shows which destinations hold which
  targets' PATs; rotating a PAT rewrites every reachable `.env` and lists the unreachable ones as
  pending; removing a destination removes its `.env` when reachable, else records that it could
  not.
- Runner operations: start, stop, restart, recreate, deploy, image rebuild and cap changes are all
  refused while the runner is `busy` unless the owner chooses Drain (stop accepting after the
  current job) or Cancel (which cancels the GitHub job first); the refusal names the job.
  Readiness per runner: the pinned runner version against the latest release (GitHub stops
  serving a runner more than 30 days behind; shown as a deadline), registered or not, the last
  registration error, a PAT lacking the permission (from the 403's header).
- Registrations: the list per target with status, busy, first and last seen; `Prune stale`
  deletes only registrations of this stack's naming shape (`<container id>-<epoch>`), labelled
  with this destination, offline and idle for more than 10 minutes, revalidated right before each
  delete, and lists what it deleted. The vendored entrypoint applies the same restriction at
  every start.
- Images: build or rebuild `rx-rust` and the runner images on the destination; show which exist
  and their age.
- Heartbeat: a destination whose probe fails three times in a row while an rx job runs there
  marks the job `lost: destination unreachable`, notifies once, and reconciles when the box
  returns; a GitHub job keeps GitHub's state. On wake from sleep the probes restart from zero,
  so sleep never produces a `lost`.

Acceptance:
- Add destination with a peer that is offline ends at the reachability step with `peer offline`
  and writes nothing to the rules file.
- Deploy writes `.env` with the PAT from the Keychain item and nothing from the PAT appears in the
  ledger, the local log or the streamed output (a test greps for the fixture token).
- Stop and recreate are refused while the runner is `busy` and the refusal names the running job;
  Drain stops it after the job ends.
- Prune deletes only registrations matching the shape, the label and the age, and lists them; a
  registration that came back online between listing and delete is skipped.
- Three failed probes during a running rx job flip it to `lost` with the reason and one
  notification; the box returning with `.rc` present flips it to `done` or `failed` with box
  timing. Probes failing while the Mac was asleep do not count.

/goal: the U6 tests pass; a dry deploy to `ai-eu-1` (the stack already there) is a no-op
that reports every runner's state and version; `$SCRATCH/review-out.md` prints 0 P0-P2.

### U7. Panel UI, menu bar icon, Settings
Per `docs/DESIGN.md`. Tabs: Jobs, Destinations, Routing, History (U8). Menu bar icon states: idle,
n running (the count), failed (badge until seen), tailnet down (slashed). Settings panes: General,
Tailscale, Destinations, Hooks, Retention, Notifications, Agent access, About. Footer: poll ages,
rate budget, Restart, Quit.

Acceptance (offscreen renders from DemoShots data, checked by the review against DESIGN.md, plus
the layout tests below):
- A running rx row shows repo, branch and worktree, command, destination, agent, elapsed, the
  age of the last output line, and the current phase (`syncing 12 s`, `running`); a running GitHub
  row shows the current step `3/7 cargo test`.
- A queued GitHub row shows the wait, the labels, the observation counts and the observed-at time.
- A failed row shows outcome, duration, location and fallback reason (when local) and has `Log`
  and `Rerun` visible without expanding; a local row that failed is `failed` in `crit`, with
  `local` as its location chip, never a third state.
- A repo name of 48 characters, a workflow name of 60 and a reason of 120 wrap by the rules in
  DESIGN.md at 404 points without clipping (a layout test renders them).
- Destinations cards show roles, rx slots used of configured, the memory budget used, runners with
  version and readiness, and stale markers with last-success times on every measurement older
  than its poll interval; an offline card keeps the actions that do not need the box (cached logs,
  GitHub registration prune) and shows the reason in place of the others.
- Routing shows the tenant deny, the rules, the GitHub label mapping with mismatches, and the
  explain with the inputs it used.
- Every view renders in the three looks without a glitch from LESSONS.md section 4; Restart and
  Quit are present and follow the U4 detachment contract (a running remote job is not cancelled by
  Quit; the dialog says so).

/goal: `--render-screenshots` produces every view from DemoShots data, the layout tests pass, the
owner approves the renders (recorded in LOG.md), and `$SCRATCH/review-out.md` prints 0 P0-P2.

### U8. History
- Sortable rows for 30 days with measured durations (with provenance), waits, outcomes, locations
  and fallback reasons; filters by destination, repo, state, source, agent, the same as
  `rmj jobs`. Per repo: runs, median and last duration, waits, local fallbacks and their reasons.
  A day strip at the top with counts by state.
- Warmth is `unknown` unless the rule's `cold_marker` map names this repo (a log line such as
  `Compiling libduckdb-sys` whose presence means a cold build); then `cold` or `warm`. No
  duration heuristics.

Acceptance:
- With `cold_marker: {"acme/atlas": "Compiling libduckdb-sys"}`, the atlas run whose
  log contains it is `cold`, the others `warm`; an axon run under the same rule is `unknown`.
- `rmj jobs --repo atlas --state failed --since 7d` and the Jobs tab's search and filter chips give the same rows.

/goal: the U8 tests pass and the owner approves the renders.

### U9. Hooks for every harness
- `rmj hooks install|status|remove [harness]`. Claude Code: a `PreToolUse` Bash hook entry in
  `~/.claude/settings.json` that calls `rmj guard` (the port of
  `~/agent-os/hooks/shared/remote-build-guard.sh`; its 38 cases ported, plus contextual cases:
  `cd dir && cargo test`, `FOO=1 cargo test`, `bash -c '...'`, `(cargo test)`, `cargo test || true`,
  a command inside a heredoc). Codex, OpenCode, Hermes: the same guard through each harness's
  pre-command hook where one exists; where none exists, shims for `cargo` and `just` under
  `~/.rmj/shims` injected only into that harness's environment (decision D2, settled at U9 after
  checking each harness), each shim resolving the real binary by PATH minus the shim dir.
  `scripts/check.sh` cannot be shimmed (a path, not a PATH lookup) and the Settings row says so.
- The guard blocks the matched command shapes in a classified repo and prints the `rmj run`
  form (with `--shell` when the command has shell syntax), whether the router's answer is remote
  or local, so local fallbacks are recorded too; it passes `RX_LOCAL=1`, anything already under
  `rmj run`, and commands in an unclassified repo (with one advisory line naming the repo). The
  guard is routing assistance, not the tenant boundary: the deny lives in the router.
- Idempotent: install twice yields one entry; remove restores the file except the entry. Settings
  > Hooks shows each harness as installed, not installed, not present on this Mac, or covered by
  shims only.
- The agent-os `link.sh` stops installing the old guard once this ships (decision D1).

Acceptance:
- The 38 guard cases pass against `rmj guard` (same inputs, same verdicts), plus the contextual
  cases above.
- A command in a repo whose rule routes `local` is still rewritten to `rmj run` (recorded);
  one in an unclassified repo passes with the advisory line.
- Install on a `settings.json` with other hooks keeps them and adds one entry; a second install
  changes nothing; remove leaves the other hooks untouched.
- A harness not present on the Mac is reported `not present`, never installed into a path that
  does not exist; the shim for `cargo` runs the real `cargo` for `cargo build`.

/goal: `rmj hooks status` lists Claude Code installed on this Mac; in a Claude Code session,
`cargo test` in axon is blocked with the `rmj run -- cargo test` form; `$SCRATCH/review-out.md`
prints 0 P0-P2.

### U10. CLI JSON and `rmj mcp`
Per `docs/AGENT-API.md`, which holds the schemas. Every CLI verb has `--json`. `rmj mcp` is
read-only (explain is allowed: it runs nothing), off by default (Settings > Agent access), fails
closed on an unreadable config; the switch governs MCP exposure only and the doc says which CLI
verbs an inspection-only agent must be denied by its harness.

Acceptance:
- Every tool's output validates against its `outputSchema`; `jobs` paginates with `cursor`;
  responses are capped at 1 MB with `truncated: true`.
- `log` answers from the local archive only; a log that is `pending` or on an offline box returns
  `{"available": false, "reason": ...}` within the budget, never an ssh.
- With agent access off, a tool call returns `isError: true` with the sentence from AGENT-API.md
  and no data; `initialize` and `tools/list` still answer; supported MCP versions are the two
  pinned in the doc.
- A log returned to an agent has escapes and invisible Unicode stripped and carries the
  `data_note`; a job id or path argument that is not a ULID or not under the archive is `-32602`.

/goal: the MCP smoke test passes and `$SCRATCH/review-out.md` prints 0 P0-P2.

### U11. Updater, About, login item, notifications
From MacMax: the release check, Update in About, Start at login. Notifications: failed or lost
job (repo, command, destination, duration, reason, a button that opens the log), a destination
unreachable during a job (once), optional job done. Secrets never appear in a notification.

Acceptance:
- A failed job yields one notification whose body contains no PAT fixture value and whose action
  opens the local log; a second failure of the same job id does not notify twice.
- The release check against a fixture feed shows the arrow in the header and About offers Update;
  an unreachable feed changes nothing and logs once.

/goal: the U11 tests pass; the installed build shows the arrow against a newer fixture release;
`$SCRATCH/review-out.md` prints 0 P0-P2.

### U12. Release
MacMax's `docs/RELEASE.md` ceremony with the names changed: ad hoc signing, reproducible zip,
`SHA256SUMS`, `install.sh`, the Homebrew cask in `danieltamas/tap`, README media rendered from
DemoShots per `docs/SCREENSHOTS.md`, SECURITY.md final, the release notes naming the s1 scenario
as pending (D6).

Acceptance: `scripts/acceptance.sh` steps 1 to 6 pass; the README's claims are each true on the
release day (a checklist in the PR).

/goal: `scripts/acceptance.sh` exits 0 on the tag and the release is public.

### U13. s1 through the app
The first Globex destination is added through Settings > Destinations > Add, the runner stack for
the Globex repos (gateway first) deployed from the panel, the PAT from the Keychain. Executed only
after the owner says Globex starts.

Acceptance: the add flow's checks pass on s1; a gateway workflow job runs on its runner and
appears in Jobs; `rmj run` from a Globex checkout lands on s1 and is denied for `ai-eu-1`.

/goal: those three facts recorded in LOG.md with run ids.

### U14. Agent runs
Design and measurements: `docs/AGENTS-ON-BOXES.md`. An agent run is an ordinary run (U4) of `claude -p` in the `rx-claude`
image, plus three things around it: the Mac's Claude login reaches the container without touching the box's disk, the box
enforces a deadline, and the result comes back as a branch.

Interfaces (RMJCore/Run, public unless noted):
- `AgentTask { prompt: String, unattended: Bool, allowedTools: [String], timeoutSeconds: Int, requireBox: Bool }` with
  `func argv(onBox: Bool) -> [String]`. Box argv: `["timeout", "--signal=TERM", "<timeoutSeconds>", "claude", "-p", prompt,
  "--permission-mode", unattended ? "bypassPermissions" : "acceptEdits"] + (allowedTools.isEmpty ? [] : ["--allowedTools"] + allowedTools)`.
  Local argv: `["claude", "-p", prompt]` plus the same `--allowedTools` words, and never a permission mode.
- `RunRequest.agentTask: AgentTask?` (init parameter, default nil). `RunRequest.command` carries the local argv.
- `protocol CredentialSource { func load() async throws -> Data }` returning the raw JSON of the Claude Code Keychain item
  (`{"claudeAiOauth": {accessToken, refreshToken, expiresAt (ms), ...}}`); `KeychainCredentials` reads it with
  `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. `RunEngine.init(..., credentials: CredentialSource)`.
- `AgentCredentials.stage(raw: Data, now: Date, minimumLifetime: TimeInterval) throws -> Data`: the JSON to put on the box,
  with `refreshToken` and `refreshTokenExpiresAt` removed; throws `AgentCredentials.Failure.expiresSoon` or `.unreadable`.
- `BoxClient` gains, with default implementations that throw `BoxFailure("unsupported")` / do nothing so existing fakes compile:
  `stageSecret(ulid:name:content:) async throws -> String` (the directory path on the box), `discardSecret(ulid:) async`,
  `pullTree(_ job: BoxJob, into local: URL) async throws`.
- `AgentBranch.snapshot(worktree: URL) async throws -> String` (tree id of what the sync sends) and
  `AgentBranch.record(worktree: URL, base: String, result: URL, jobID: String, message: String) async throws -> AgentBranch.Outcome`
  (`.unchanged` or `.created(branch: String, commit: String)`).
- CLI: `rmj agent run [--to dest] [--timeout 30m] [--unattended] [--allow "Tool,Tool"] [--require-box] -- "<prompt>"`.

Behaviour:
- Routing is the existing router with the command word `claude`: a rule `{match: {command: ["claude"]}, to: [...], image:
  "rx-claude", cpus: 2, memory: "4g"}` opts in. No matching rule, no box, tailnet down, a failed sync: the agent runs on the
  Mac (local argv), the ledger says why. `--require-box` turns every such fallback into a failed job (exit 3), nothing runs.
- Credentials: read on the Mac before the lock is taken; the access token must have at least 10 minutes left, else the run
  falls back (reason `claude login expires soon`). The staged JSON is written by `rx-run.sh secret` into a 0700 directory on
  tmpfs (`$XDG_RUNTIME_DIR` or `/dev/shm`), bind-mounted at `/run/rmj`, moved into `$HOME/.claude/.credentials.json` inside the
  container by a prelude, and removed (`unsecret`) when the run ends or fails to start. The token is never in argv, `docker
  inspect`, the prelude, the ledger, a log or a notification. The refresh token never leaves the Mac.
- Result: before the sync, `AgentBranch.snapshot` writes a tree of the worktree as the sync sees it (HEAD plus uncommitted
  and untracked-unignored files, minus the sync's own excludes). After the run, `pullTree` mirrors the box directory into a
  temp directory (rsync `--safe-links`, no `.git`, `.rmj`, `node_modules`, `target`, files over 25 MB skipped), and
  `AgentBranch.record` makes a tree from it with a temporary index (seeded from the base tree, so tracked files the sync
  excludes stay), and if it differs creates a commit with HEAD as parent and the ref `refs/heads/rmj/agent/<job id>`. Git
  plumbing only: the worktree, its index, its HEAD and its branches are never written; no `git apply`, no checkout. A `.git`
  directory, a symlink that leaves the tree and oversized files in the result are not imported.
- The deadline is `timeout` inside the container; the box also removes the container on cancel as for any run.

Acceptance:
- No rule for `claude`, or the tailnet down: the command runs on the Mac with the local argv and the row's fallback reason is
  set; with `--require-box` the job is `failed`, exit 3, and nothing ran.
- A fake box sees `stageSecret` before `go`, with JSON that has `accessToken` and no `refreshToken`; the strings of both tokens
  appear in no `go` argument, no option, no prelude, no ledger column or event, no log and no notice; `discardSecret` is called
  after a normal run, a failed run, a start failure and a cancel.
- A token with less than 10 minutes left falls back with reason `claude login expires soon` and stages nothing.
- Box argv starts with `timeout --signal=TERM <seconds>`; `--unattended` appears only in the box argv, never in the local one.
- Result branch: a modified, a new and a deleted file (plus a file that was uncommitted before the run) produce a commit on
  `rmj/agent/<id>` whose parent is the HEAD at the start and whose tree equals the box's tree; an unchanged tree creates no branch.
- The worktree is byte-identical afterwards (files, index, HEAD, branch list apart from the new ref, `git status` output).
- Hostile result (a `.git` directory with a hook, a symlink to `/etc/passwd`, a 30 MB file, a file named `a\nb`, a `.gitmodules`):
  no file outside the temp directory is read or written, the branch contains no `.git`, no outside symlink, no oversized file.
- `rmj agent run` parses its options; an unknown option is exit 2.

/goal: the acceptance tests green; live: `rmj agent run --to ai-eu-1 -- "<task>"` on a Rust or Node repo returns a branch whose
diff is the task, the box holds no token afterwards (`grep` of /dev/shm, the home and docker inspect finds nothing), and
`$SCRATCH/review-out.md` prints 0 P0-P2.

### U16. Box streams
One long-lived ssh session per enabled destination replaces the app's periodic probe. The box's own shell loop prints a probe
frame every `frameInterval`; the Mac reads frames as they arrive. A box that stops answering goes grey on its own, without
any probe having to fail. Nothing is installed on the box: the loop is the argv of the ssh command, it reads only, it opens
no port. The one-shot `DestinationProbe.probe` stays for the CLI (`rmj route`) and the runner scaler, which are not the app.

Interfaces (RMJCore/Net, public unless noted):
- `protocol StreamTransport: Sendable { func stream(address: String, alias: String, script: String, output: @escaping @Sendable (Data) -> Void) async throws -> Int32 }`:
  runs `script` on the box, hands every stdout chunk to `output`, returns the exit status when the session ends, throws on
  cancellation. `SSHStreamTransport` is the real one: `SSH.arguments` (so StrictHostKeyChecking, ControlMaster and
  `ClearAllForwardings=yes` apply) through `ProcessRunner.run` with a very long timeout and its `output` callback; cancelling the task
  kills the ssh. No second process primitive.
- `DestinationProbe.streamScript(requires:images:interval: Int, heavyEvery: Int, rareEvery: Int) -> String`: a counter loop
  `i=0; while :; do <steps>; echo @@end; i=$((i+1)); sleep <interval>; done`, one frame per turn, the existing step commands and
  `@@name rc=N` section format unchanged. The steps run in three tiers so the stream is cheap on the box: the **light** tier
  (every turn; kernel files only, no docker, no dmesg, no smartctl: clock, mem, memtotal, load, boot, uptime, cpustat, swap, net,
  psi, hwmon, disk, clockend) and, when `i % heavyEvery == 0`, the **heavy** tier (docker, containers: `docker info`, `docker ps` and `docker stats --no-stream`),
  and, when `i % rareEvery == 0`, the **rare** tier (rsync, images, nproc, diskhealth, osname, virt, tools). Turn 0 runs all three, so the
  first frame is complete. Defaults: interval 10 s, heavyEvery 6 (60 s), rareEvery 30 (5 min). A box whose `sleep` is missing, or whose shell exits,
  ends the session (exit status reported). The box-side loop dies with the session: when ssh goes away the next write to the closed pipe ends it.
- `DestinationProbe.lightSections` / `heavySections` / `rareSections` (static, `[String]`): the tiers by section name; a frame is *valid* when it
  carries every light section and `@@end`. `SectionCache` (internal, a struct): `merge(frame sections)` keeps the newest copy of each section with the time it arrived;
  a heavy or rare section not refreshed within three times its period is dropped (the reading becomes unknown, never an old value presented as current).
  The result is built from the merged sections by the same code `DestinationProbe.parse` uses (refactor `parse` into `sections(from:)` + `result(from:)`; the one-shot probe keeps working).
- `FrameAssembler` (internal): feeds on arbitrary chunks, yields complete frames (text from the first `@@` header up to and
  including `@@end`); bytes before the first header are dropped; a frame larger than 256 KB is dropped and the assembler
  resynchronises at the next `@@clock`; a chunk boundary anywhere (inside a header, a UTF-8 sequence, `@@end`) changes nothing.
- `actor BoxStream`: `init(target: DestinationTarget, transport: StreamTransport, tailnet: @escaping @Sendable () async -> TailnetState,
  clock: @escaping @Sendable () -> Date = Date.init, timing: BoxStream.Timing = .standard, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
  onResult: @escaping @Sendable (DestinationProbeResult) -> Void)`, `start()`, `stop() async`, `var latest: DestinationProbeResult? { get }`.
  `BoxStream.Timing { frameInterval: Int (10), heavyEvery: Int (6), rareEvery: Int (30), silence: Duration (30 s: three intervals), backoff: [Duration] (2, 4, 8, 16, 32, 60 s, then 60 s), jitter: Double (0.2) }`.
- `DestinationProbeResult.unreachable(_ availability: Availability) -> DestinationProbeResult` (public): the same readings and the
  same `probedAt`, with the availability replaced. That is how an offline card keeps showing the last good numbers, dated.
- `actor BoxStreams`: `ensure(destinations: [String: DestinationTarget])` starts a stream per target, stops the streams of
  removed or disabled ones, restarts one whose target changed (alias, address-relevant fields, requires, images);
  `latest() -> [String: DestinationProbeResult]`; `stopAll() async`. The app's PanelModel owns one and reads `latest()`.

Behaviour (acceptance lines, each testable with a fake transport, a fake clock and an instant `sleep`):
1. Before every connect, `DestinationResolver.resolve(target, in: await tailnet())` must give `.online(address)`; the transport
   is called only with that address. Not online: no connection is made, `onResult` gets the last good result `.unreachable(thatAvailability)`
   (or `.without(thatAvailability)` when there never was one), and the stream retries when the tailnet is looked at again.
   An address is re-verified on every reconnect, never cached.
2. Each complete frame is merged into the section cache and the result built from it (`probedAt` = the clock at the frame's arrival). A frame that
   is not valid (a light section missing, a bad header) is dropped and counts as no frame: it is never published as a healthy reading.
   A light-only frame after a full one keeps the box's containers, images and disk health (until three periods old), and updates load, memory, network and the rest.
   A frame published sets `latest` and calls `onResult` with an `.online` result.
3. The session ending (any exit status, an error, a transport throw) publishes the last good result `.unreachable("ssh exit N: ...")`
   at once, then reconnects after the next backoff delay plus or minus `jitter` (the delay list resets after a frame is received).
   No connect happens while a previous session is still running.
4. Silence: no complete frame for `silence` while the session is up (a hung ssh, a stopped box that never closed the TCP
   connection) publishes `.unreachable("no frames for 30 s")`, cancels the session and reconnects as in 3. The check runs on the
   same clock, so the test controls it.
5. The tailnet saying the destination is no longer online while a session runs cancels the session at the next check and
   publishes the resolver's availability (offline, unreachable or rejected) with the last good readings.
6. `stop()` cancels the session and any pending reconnect, and publishes nothing afterwards.
7. The script the transport receives is `DestinationProbe.streamScript(requires: target.requires, images: target.images, interval: timing.frameInterval, heavyEvery: timing.heavyEvery, rareEvery: timing.rareEvery)`,
   and contains no `sudo`, no `nc`, no `socat`, no listening construct (`-l`), and writes nothing to the box's disk (no redirection to a file other than `/dev/null`).
8. Display rule for an offline box (`DestinationCardPresentation`, RMJCore/Panel): when the availability is not online, every
   capacity line, every sensor chip and every runner line is drawn in the unknown tone, the "as of HH:mm" marker is present
   (the probe is older than one poll interval by definition), and a runner line's state reads "unknown, box offline". Counts
   that are measurements (`rx 0 of 3`) are never shown as a fresh zero: the last good reading, grey, or nothing.
9. PanelModel starts and stops streams from the rules (a destination added, removed, disabled, edited) and does no
   `DestinationProbe().probe` for a box it streams; the 30 s / 5 min probe timers are gone from the app. The scaler and the CLI still probe.
10. Cost (very cheap is a requirement, not a hope). On the box: the light tier starts at most 14 short commands per turn (a command being a
    process the shell spawns) and none of `docker`, `dmesg`, `smartctl`, `lsblk`, `findmnt`, `systemd-detect-virt`; `docker` appears only in the heavy and rare tiers;
    one frame of the light tier is under 3 KB of output; the heavy tier is the only place `docker stats` runs, once per `heavyEvery` turns. On the Mac:
    a frame is parsed once and merged (100 light frames merge in under 100 ms in a test), a published result that equals the previous one in everything but
    `probedAt` does not call `onResult` more than once a minute, a frame costs PanelModel nothing until the loop's own beat reads it (no rebuild or database
    write per frame; the beat is the existing 15 s while hidden and idle), and no timer runs per box except the single watch beat (one second).

Measured by: the unit tests above; `scripts/acceptance.sh perf` with every destination streaming stays under 0.3 percent CPU idle;
and the live scenario recorded in LOG.md: with the app open and a box up, power the box off; the card pill, runner dots and
tiles go grey within `silence` + 5 s (command, timestamps, observed delay); and the cost, measured live and recorded: the
box's CPU time for one light frame and for one heavy frame (`time sh -c '<script turn>'`), and the app's CPU over ten minutes of streaming one box and all boxes.

### U17. Tenants: style, group order, tagging a job
A tenant is a company or a person's own set of repos; its boxes form a group. Settings shows them, the owner colours and orders them,
and a local job whose repo no tenant claims gets a tenant from the job list. All of it is `rules.json`; nothing new is stored.

Interfaces (RMJCore/Routing, public unless noted):
- `TenantConfig` gains `style: TenantStyle?` and `order: [String]?` (both optional; old files load unchanged). `TenantStyle`: `color: String?`
  (`#RRGGBB`), `pattern: String?` (`none`, `stripes`, `dots`), `width: Double?` (px of a stripe or the diameter of a dot, 1...32),
  `size: Double?` (px between stripes or dot centres, 4...64), `angle: Double?` (degrees, -180...180), `scatter: Double?` (0...1, how far
  each dot or stripe is moved off the regular grid; 0 is regular). `TenantStyle.resolved(for tenant: String) -> TenantStyle.Resolved`
  fills every field: colour `TenantStyle.defaultColor(for:)` (a stable `#RRGGBB` from the name, the same hue the app's wash uses today),
  pattern `none`, width 3, size 10, angle 45, scatter 0.
- Validation (`RulesValidation`, unknown keys stay refused): `tenant` allows `style` and `order`; `style` allows the six keys above; a
  colour that is not `#` plus six hex digits, a pattern outside the three, or a number out of range fails the load with a message
  naming the tenant and the field; `order` may list only destinations whose `tenant` is this tenant, each once.
- Priority: a rule's chain is tried in the order written, except that the destinations of one tenant that appear in the chain take, among
  the places they occupy, the order of that tenant's `order` (those not listed follow, in their written order). `Tenancy.ordered(_ chain:
  [String], destinations: [String: DestinationConfig], tenants: [String: TenantConfig]) -> [String]`; `Router.route` uses it before it
  tries the chain, so box1, box2, box3 are tried in that order and the explain lists them in the order tried. `local` still ends the chain.
- `TenantOverview.summaries(_ rules: Rules) -> [TenantOverview.Summary]`, sorted by name: `name`, `shared`, `owners`, `repos`,
  `destinations: [String]` (the tenant's destinations in priority order: `order` first, the rest by name), `isGroup` (two or more
  destinations), `style: TenantStyle.Resolved`.
- `TenantEditing.apply(_ change: Change, home: RMJHome, expected: String? = nil) throws` as `RuleEditing.apply` (read, change, validate,
  write, refuse when the file changed): `.style(tenant, TenantStyle?)` (nil removes it), `.order(tenant, [String])`,
  `.assign(repo: String, tenant: String)`. `assign` adds the lower-cased `owner/name` to `tenants.<tenant>.repos` unless the tenant
  already claims it; it throws `Failure` when the tenant does not exist, when the repo is not `owner/name`, or when another tenant's `repos`
  already claims it. `TenantEditing.assignable(_ rules: Rules) -> [String]`: the tenants that have at least one enabled destination.
- `JobRowPresentation.canTag: Bool`: true for a job that ran locally, is not a GitHub job, and whose tenant is `unclassified`; its repo is
  `title`.

Acceptance:
- A file with no `style`/`order` loads and routes as before; `resolved(for:)` is stable across calls and runs, and two different names get
  different default colours.
- Each invalid style field and each invalid `order` (unknown destination, another tenant's destination, a duplicate) fails the load.
- Chain `[box3, box1, box2]` for tenant `acme` with `order: [box1, box2, box3]` is tried box1, box2, box3; a chain that mixes tenants keeps
  the other tenant's destinations in their own places; the tenant deny and `local` termination are unchanged.
- `summaries` marks a tenant with two destinations as a group and lists them in priority order; a tenant with none lists none.
- `apply(.style)` and `.order` persist and round-trip through `RulesStore.load`; `.assign` makes `Tenancy.resolve` return the tenant for that
  repo, the next `Router.route` of it is no longer "unclassified repo", and the other tenants' tables are untouched; an `.assign` to a repo
  another tenant claims, or to a missing tenant, changes no byte of the file.
- `canTag` is true only in the case above (false for a remote job, a GitHub job, a classified local job).

/goal: the acceptance tests green and `scripts/check.sh` ok; live: in the installed app a tenant gets a colour and a stripe pattern in
Settings, the Tenants pane lists each tenant with its boxes in order, and an unclassified local job's tag control assigns its repo.

### U18. Live sensors
While the panel or a box card is on screen, boxes report every 2 s and the card moves with them; hidden, they report every 10 s as in U16.
Mechanism: the box-side loop already prints a light frame per interval; the Mac asks a stream to change its interval, the stream restarts its
session on the existing ssh connection (about 20 ms), and each frame reaches the UI as it arrives.

Interfaces (RMJCore/Net):
- `BoxStream.setFrameInterval(_ seconds: Int) async`: no effect when equal to the current one; otherwise the session ends and a new one starts
  at once (no backoff, the delay list is untouched), with the script built for the new interval. `BoxStream.Timing.frameInterval` is the
  interval a stream starts with. `heavyEvery` and `rareEvery` are re-derived so heavy stays at 60 s and rare at 300 s (`60 / interval`,
  `300 / interval`, at least 1). `silence` is three intervals (at least 30 s).
- `BoxStreams.setFrameInterval(_:) async` for every stream, and streams started afterwards use it.
- `BoxStreams.init(... onFrame: (@Sendable (String, DestinationProbeResult) -> Void)? = nil)`: called for every published result, without the
  60 s repeat suppression that `onResult` has; PanelModel uses it to refresh at once.
- The app: panel visible or the Destinations settings pane showing, 2 s; otherwise 10 s. Sensor values, clock and network rates move at that pace;
  the history sample step (30 s) and the ledger writes do not change.

Acceptance:
- `setFrameInterval(2)` ends the running session and the transport's next script has `sleep 2` and heavy every 30 turns; the same value twice
  starts no second session; no backoff delay is slept between the two sessions.
- A frame received at interval 2 reaches `onFrame` and `latest` before the next frame; two equal frames reach `onFrame` twice.
- The cost: the light tier unchanged (U16 line 10); at 2 s the Mac parses 100 frames in under 200 ms in a test.

/goal: acceptance tests green and `scripts/check.sh` ok; live: the installed app, panel open, shows a card's CPU and network values change at about
2 s (timestamps recorded in LOG.md), and 10 s again 5 s after the panel closes; the app's CPU while live is recorded.

## Quality criteria (every unit)

- Code: Swift 6 strict concurrency, files under 500 lines, no third-party packages,
  intention-revealing names, comments say why, no dead code, the file's idiom. Acceptance tests
  by Codex; regression tests by the implementer for defects found.
- Speed: idle CPU under 0.4 percent, under 2 percent while streaming one job; panel opens in under
  150 ms from the SQLite ledger; the router answers in under 20 ms from cached state; a probe never
  blocks the UI (actors and timeouts).
- Security (SECURITY.md): ssh only to verified tailnet addresses with the fixed argv; argv
  everywhere, `--shell` explicit; PATs in the Keychain and in the documented remote `.env` only;
  redaction before persistence; logs and GitHub text untrusted; tenant deny tested; MCP read-only
  and off by default; rules failure fails closed to local.
- Docs: README screenshots from DemoShots, every user-facing claim true on the day of release,
  LOG.md entry per unit with evidence.

## Open decisions

- **D1. Ownership of rx and the guard.** Recommended: RMJ owns them from U4/U9 on; `~/agent-os`
  keeps `rx` as an alias of `rmj run`, `rules/remote-build.md` points here, `link.sh` stops
  installing the old guard. The owner decides at U4.
- **D2. Shims for harnesses without a pre-command hook.** Settled at U9 after checking Codex
  0.160, OpenCode and Hermes for hooks; shims cover `cargo` and `just` only.
- **D3. A second surface on the box.** Not in v1 unless the owner asks.
- **D4. Icon.** Decided 2026-10-27: a route from one source (the Mac, a white dot) to two
  destinations (boxes); the chosen branch is lit in the brand gradient (blue `#5B8CFF` to teal
  `#2FD3C8`) and ends in a filled box with a play mark (running), the skipped branch is dim and
  ends in an outlined box. `Brand/icon-app.svg` on the family's dark rounded square,
  `Brand/icon-menubar.svg` the same route as a template glyph at 18 points; the app draws the
  running count and the failed badge beside it. The theme's `brand` hue derives from the
  gradient; `running` is the teal.
- **D5. GitHub-hosted jobs in the Jobs list by default.** Default on, recommended.
- **D6. v0.1.0 before Globex starts.** Recommended: ship with the s1 scenario fixture-tested and
  recorded as pending; U13 lands in a later release.
- **D7. Keychain sharing between the ad hoc app and the CLI.** Settled by `scripts/keychain-check.sh`
  in U0; the fallback is in U0.
- **D8. Rules file format.** JSON (Codable, Foundation only), decided 2026-10-27 after the review:
  a TOML parser with no packages is v1 infrastructure the app does not need; the app edits the
  file anyway.

## U19. Agent runs: sessions and model

`rmj agent run` gains what a caller such as Bton needs to run its own `claude -p` calls on a box (docs/BTON-INTEGRATION.md,
gaps 1 and 3). Gap 2 (push and `gh` inside a run) stays out by design: the box holds no push credential, the result is
the branch `rmj/agent/<id>`, and the caller pushes it from the Mac.

Interfaces:
- `rmj agent run [--model <name>] [--session-id <uuid> | --resume <uuid>] ...`. `--model` is `^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,63}$`
  and works for both harnesses (`claude --model`, `codex exec -m`). The session flags are Claude only, take a UUID (any case,
  stored lowercase), and are exclusive with each other; anything else is the usage error (exit 2).
- `AgentTask` gains `model: String?` and `session: AgentTask.Session?` (`id: String`, `resume: Bool`).
  `argv` appends `--model <m>` and `--session-id <id>` or `--resume <id>` to the claude command (local and box variants) and
  `-m <m>` right after `exec` for codex.
- Persistence: a run with a session mounts the box directory `<home>/rx/.sessions/<key>` at `/tmp/.claude/projects`
  (the container's HOME is its tmpfs `/tmp`), where `<key>` is the first 16 hex characters of the SHA-256 of the repo slug
  (the Mac worktree path when the repo has no slug). The login never lands there (it stays at `$HOME/.claude/.credentials.json`
  on the tmpfs). `rx-run.sh` creates the directory (mode 0700, the box user's) before `docker create` and `prune` deletes
  session files older than 14 days. A run without a session mounts nothing.

Acceptance:
- Parsing: the flags above, each invalid value and each exclusive pair is exit 2 with the usage line; defaults unchanged.
- argv: the exact claude and codex vectors with and without model and session, local and on the box; a prompt that looks like
  a flag stays one argument.
- `decorate` mounts the sessions directory only when a session is set; the same repo gives the same directory, two repos
  differ, the host path is under `<home>/rx/.sessions/`, nothing else of the home is mounted, the credentials path is
  unchanged.
- `BoxAssets.script` creates `.sessions/<key>` with mode 700 for such a volume before `docker create`, only for a path under
  `$HOME/rx/.sessions/`, and prunes session files older than 14 days.

/goal: `scripts/check.sh` passes, a live `rmj agent run --require-box --session-id <uuid> -- "remember the word kiwi"` then
`--resume <uuid> -- "what word?"` answers kiwi (on the box the claude rule names), and the box shows no credentials file under `~/rx/.sessions`.

## U20. Agent runs: attachments, a system prompt file, a machine-readable result

What a caller that runs review agents on a box needs (docs/BTON-INTEGRATION.md, gaps 6 to 9; 12 is a rules fix, 10 and 11 are
deferred, 13 stays local). Gap 7 is settled by the caller attaching the PR diff as a file through `--attach`; shipping a git
bundle is deferred until the fix and resolve moves run on a box.

Interfaces:
- `rmj agent run [--attach <dir>]... [--append-system-prompt-file <path>] [--json] ...` (Claude only for the prompt file;
  `--attach` and `--json` work for both harnesses).
- `--append-system-prompt-file <path>`: a regular file, UTF-8, 1 to 65536 bytes, given at most once, read when the options are
  parsed; claude plus this flag with `--harness codex`, an unreadable, empty, oversized or non-UTF-8 file, a second use: usage
  error (exit 2). `AgentTask.systemPrompt: String?`; `argv` (local and box) inserts `--append-system-prompt <text>` right
  after `--model <m>` when present, otherwise after the prompt options as for `--model` today (model, then system prompt, then
  session, then tools). The text is one argv element, never a shell word.
- `--attach <dir>`, up to 4: an absolute path to an existing directory with no `..` and only the characters
  `A-Za-z0-9._/+@=-`, not `/` and not at or under `/work`, `/tmp`, `/run`, `/proc`, `/sys`, `/dev`, `/etc`, `/usr`, `/bin`,
  `/sbin`, `/lib`, `/opt`, `/root`, `/home`; total size at most 50 MiB (measured with a dry-run rsync, over the limit the run
  fails before anything is sent: exit 2 for the shape, the ledger reason "attachment too large" and the Mac fallback for the
  size). `AgentTask.attachments: [String]` (the standardized paths). On a box: after `sync` and before `go`, each directory is
  sent (`rsync -a --safe-links --delete`, no ignore list: the caller chose these files) to `<home>/rx/.attach/<ulid>/<index>`
  through the new `BoxClient.sendAttachment(ulid:index:from:) -> String` (default implementation throws, so existing fakes
  compile) and mounted `-v <box dir>:<same path as on the Mac>:ro`. `AgentSession.decorate(_:home:slots:repo:attachments:)` takes `[AgentSession.Attachment]` (`Attachment(boxDirectory: String, path: String)`, default `[]`).
  Locally nothing is done: the paths already exist. `discardSecret` also removes `.attach/<ulid>`; `prune` removes
  `.attach` entries older than 1 day.
- `--json`: the last line the command prints is one JSON object with sorted keys `branch` (`rmj/agent/<ulid>` when a branch
  was created, else null), `exit` (the command's exit code), `final` (string or null), `job` (the ULID), `location`
  (`local` or the destination name). `final` is the `result` string of the stream-json `result` event on a box run
  (`AgentStream.finalText`), the trimmed stdout of a local run; both cleaned with `UntrustedText.clean`, at most 65536 bytes.
  A run that never got a job (usage error, exit 2) prints no JSON. `RunResult` gains `final`, `branch`, `location`.

Acceptance:
- Parsing of each flag: valid, every invalid shape above, the exclusions, defaults unchanged.
- argv: exact vectors with system prompt, model and session together, local and box, a prompt text with spaces, quotes and
  a leading `--` stays one element.
- `decorate` with attachment box paths mounts exactly `-v <box>:<mac path>:ro` per attachment and nothing else new.
- `AgentStream.finalText` is the `result` event's `result` (last one wins), nil without one, never a tool result or an
  assistant text; terminal escapes are removed by the JSON builder.
- `AgentRunCommand.jsonLine(job:location:branch:exit:final:)` is a single line, keys sorted, `final` escaped and truncated at 65536
  bytes, nulls for nil.
- The engine, with a fake box client: the attachment is sent after `sync` and before `go`, the mount is in the job's
  options, a failing send falls back to the Mac with the reason "attachment could not be sent" (or fails when `--require-box`),
  `RunResult.final` and `.branch` are set from a stream with a result event and a created branch.
- `BoxAssets.script` prunes `.attach` entries older than 1 day and `discardSecret` removes `.attach/<ulid>`.

/goal: `scripts/check.sh` passes; live, `rmj agent run --require-box --json --attach <dir with a file> --append-system-prompt-file <file> -- "<read the attached file and answer with its first line>"` prints the first line in `final` of the last JSON line, and the box shows no `.attach/<ulid>` afterwards.
