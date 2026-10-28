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
  `gh`, the update check, and the More apps list read from the registry
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
