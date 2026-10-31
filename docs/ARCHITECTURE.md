# RMJ architecture

## Targets

```
Package.swift            swift-tools-version 6.0, macOS 14 deployment target, no dependencies
Sources/RMJCore/         everything testable; imports Foundation, Darwin, Security (Keychain),
                         SQLite3; never SwiftUI or AppKit
  Net/                   TailnetState (tailscale status --json), DestinationProbe, BoxSensors (the probe's
                         counters and SensorRates), SSH (argv builder, fixed options, address
                         verification), Rsync
  Routing/               RulesFile (Codable JSON, strict validation, atomic save), Router, Explain,
                         Tenants, RepoIdentity, Capacity
  Run/                   RunEngine (rmj run), Sync (locked), BoxRun (rx-run.sh contract: argv,
                         launch record, streaming), LocalRun, Cancel, Reconcile (.launch/.rc/.meta,
                         boot id), Warmth (cold marker)
  Registry/              the More apps list: decoder and rules (the registry's CONSUMER.md), store under ~/.rmj/registry, icon check
  GitHub/                GHClient (gh auth token, conditional requests), RunsPoller, RunnersPoller,
                         QueueReason, Rerun
  Ops/                   AddDestination, RunnerStack (deploy, start/stop, recreate when idle),
                         Registrations (list, prune), Images, Heartbeat
  Store/                 Database (SQLite actor), Schema + migrations, Retention, Queries, LogPull
  Hooks/                 Guard (the remote-build guard port), Installers (ClaudeCode, Codex, OpenCode,
                         Hermes), Shims
  Agent/                 MCPServer (JSON-RPC over stdio), MCPTools, AgentJob/AgentCLI/AgentAccess (agent runs,
                         U14), Redaction (escapes, invisible Unicode)
  Panel/                 what the app draws, as plain values the tests can read: PanelLoader and PanelSnapshot,
                         JobRowPresentation and filter, DestinationCardPresentation, SensorChips, RoutingPresentation,
                         RunReport and LogDocument, DemoShots (the fixtures behind --render-screenshots)
  Sinks/                 log streaming: config, spool, shipper, drainer, formats (see Log streaming)
  Notifications/         NotificationPlanner and settings (which events notify, once)
  Releases/              ReleaseFeed and UpdateChecker (standing, can update)
  Ops/BuildEnvironments  the shipped toolchain images (rx-rust, rx-node, rx-python, rx-go) and the programs each must hold
  GitHub/RepoStar        the footer's star offer: asks `gh` once, remembers a star in config.json
  Support/               ProcessRunner, Executables, RMJHome, Clock, SafeFile, Keychain
Sources/RMJ/             SwiftUI app: RMJApp, PanelModel (polls, holds the state the views read), PanelView,
                         JobsTab and JobExpansion, DestinationsTab and SensorViews, RoutingTab and RuleEditor,
                         ReportWindow, SettingsView + panes, Theme, Looks, Components, Collapsible (the one
                         open/close motion), UpdateInstaller (runs the bundled install.sh), StarOffer,
                         LoginItem, AlertCenter, ScreenshotRender
Sources/RMJCLI/          `rmj` (installed name): run, route, jobs, job, log, failures, destinations,
                         runners, rerun, hooks, guard, prune, mcp
Tests/RMJCoreTests/      <Topic>AcceptanceTests (Codex), <Topic>RegressionTests, Fixtures/
Support/                 Info.plist, toolchain, AppIcon.icns, MenuBarIcon.pdf
Support/box/             rx-run.sh, preludes/<repo>.sh, images/<name>/Dockerfile (shipped to boxes)
Support/runner-stack/    the vendored fleet-runners compose stack (docker-compose.yml, Dockerfiles,
                         entrypoint.sh, README.md); the source of truth once D1 is decided
Support/hooks/           the guard's shell cases (run against the installed binary)
Brand/                   SVG sources for the icons
scripts/                 check.sh, bundle.sh, install-from-source.sh, release.sh, render-icons.sh,
                         make-signing-identity.sh, perf.sh, acceptance.sh
install.sh               the one-line installer, also bundled in the app for Update
```

## What "rx" means here

`rx` was the predecessor script in `~/agent-os`; RMJ replaced it and nothing of it runs any more. `~/.local/bin/rx`
is only a forwarder to `rmj run` / `rmj jobs` / `rmj log` for stale callers (`rx facts` and `rx hosts` become
`rmj route -- true`, which reports where a command would run and runs nothing). The name survives inside RMJ as the
box-side convention, kept so boxes already set up keep working: `Support/box/rx-run.sh` (shipped to the box, starts the
container and holds the waiter), the images `rx-rust`, `rx-node`, `rx-claude`..., the `<home>/rx/` folder a run leaves
its files in, and the destination role `"rx"` (takes jobs). The Mac side is RMJ alone: RunEngine, BoxRun, Reconcile.
The contract is in docs/ROUTING.md, "The rx contract".

## Data flow

```
 agent shell ---(hook: rmj guard)---> blocked with the `rmj run` form, or passes
 rmj run -- cmd ---> Router (rules.json + cached tailnet/probe state) ---> destination | local
                       |                                   |
                       |                 Sync (rsync over ssh, tailnet address verified)
                       |                                   |
                       |                 BoxRun: rx-run.sh starts the container, streams, waiter
                       |                 writes .rc .meta .log on the box, removes the container
                       |                                   |
                       +----> Database actor (ledger: job, job_event) <---- Reconcile (.rc/.meta)
                                           ^
 GitHub pollers (runs, jobs, runners) -----+----> QueueReason, Rerun
 Destination probes, Heartbeat ------------+
                                           |
                     AppStore (@MainActor) ---> PanelView (Jobs, Destinations, Routing, History)
                                           |
 rmj CLI / rmj mcp ---(read-only SQLite)---+---> stdout JSON
```

Writers: every process (the app, each `rmj` invocation) opens the SQLite file through the same
`Database` code; the actor serialises writes within a process, SQLite (WAL, `busy_timeout` 5 s)
serialises them across processes. Every state change is one transaction with a precondition on
the previous state, so a late event never moves a settled row backwards; `job.id` is unique;
migrations take a lock row first. The app watches the file and re-queries, so the panel shows a
CLI's writes within a second. When the app is not running, `rmj run` still records everything.

## Pollers and budgets

| Poller | Active (panel open or a job running) | Idle |
|--------|--------------------------------------|------|
| TailnetState | 10 s | 60 s |
| DestinationProbe (per destination) | 30 s | 5 min |
| GitHub runs and jobs | 15 s | 120 s (300 s for a repo with no run in a day) |
| GitHub runners | 60 s | 10 min |
| Local log tail (one running rx job) | streaming | none |

Box sensors ride on the same probe (U15): `virt`, `cpustat`, `swap`, `net`, `psi` and `hwmon` steps read
kernel files only (`systemd-detect-virt`, `/proc`, `/sys`; nothing installed, no sudo) into one
`SensorSnapshot`, with every number validated and a bad step never discarding another. Counters are raw
totals: the Mac keeps the last 60 probes per box and `SensorRates` turns two of them into CPU busy percent
and network rates (a counter that went backwards, a reboot, voids the interval). The system kind (bare
metal, VM, WSL, container) decides nothing by itself: a temperature or fan chip exists only when the box
produced a reading, which WSL and most VMs never do.

Idle CPU under 0.3 percent; every poller is an actor with a timeout; a slow box never blocks the
UI; a failing poller yields a `Reading.failed(reason)` that the panel shows as unknown, never
green.

## The run engine, step by step

1. Resolve the checkout: git root, canonical origin owner and name, worktree path, branch, commit,
   dirty. Allocate the ULID and record `queued`.
2. Router: tenant deny, rules in order, chain with capacity and reachability (probe at most 60 s
   old, else one probe first).
3. Remote: ship `rx-run.sh`, the exec stub and the profile's prelude if the copies on the box
   differ (checksum); take the worktree lock through `rx-run.sh`; sync (`syncing`, its own
   duration); write the argv file; launch and read the launch record (`running`, or local
   fallback on `start-failed`); stream to the terminal, the local log copy and the panel's tail;
   while it streams, `rx-run.sh stats` is read every 10 s (`BoxLoad` parses the `docker stats` line) and the
   average goes into the job row (`avg_cpu`, `avg_memory_bytes`) like a local run's; settle from `.rc` and `.meta`
   (`done` or `failed`).
4. Local: run the argv (or `bash -c` in `--shell` mode) with the Mac's environment, location
   `local` with the reason and `environment: mac`, same streaming, same ledger, log written to the
   archive directly.
5. Cancel: `docker rm -f` by label over ssh (or SIGTERM then SIGKILL locally); the waiter records
   `cancelled`.
6. Reconcile (every `rmj` invocation, app launch, wake, 60 s while a job is `running` or `lost`):
   per online destination, read `.launch`, `.rc`, `.meta`, container presence and `boot_id` for
   each open job; settle, or mark `lost: destination rebooted` with the partial log; retry
   pending log pulls.

## Agent runs (U14)

`rmj agent run -- "<prompt>"` is an ordinary `rmj run` of `claude -p` with an `AgentTask` attached. The router, the
tenant deny and the local fallback are the run engine's own; a rule `{match: {command: ["claude"]}, image: "rx-claude"}`
sends it to a box, and `--to` still finds the destination's claude rule for the image. What the engine adds around the
box run (`AgentSession`, `AgentCredentials`, `AgentBranch`):

1. Credentials: the access token is read from the Keychain item `Claude Code-credentials` and its refresh token is dropped,
   so a box can neither renew the login nor invalidate the Mac's copy. A token with under 10 minutes left falls back
   with the reason `claude login expires soon`. The JSON goes over ssh stdin to `rx-run.sh secret` into a fresh
   directory on tmpfs (`/dev/shm` or `$XDG_RUNTIME_DIR`, mode 0700, created by that call and never reused), is
   mounted at `/run/rmj`, and a prelude moves it into the container's `/tmp`, which is a `--tmpfs`. `unsecret` runs
   when the run ends, fails or is cancelled. The token is added to the output redaction list.
2. Snapshot: before the sync, `AgentBranch.snapshot` records the tree the sync sends (HEAD, uncommitted and untracked files,
   minus the sync's fixed excludes) in the object store.
3. Result: the box directory is pulled into a scratch directory (git's own ignore list, no deletes, symlinks that leave
   the tree and files over 25 MB skipped) and `AgentBranch.record` commits it to `rmj/agent/<job id>`, parented on the HEAD
   at the start. Trees are built in an empty scratch repository that borrows only the checkout's object store, so the
   checkout's config, filters, attributes and hooks never run on what the agent returned; the worktree, its index
   and HEAD are never written. A result that cannot be imported returns exit 4.
4. `--require-box` turns every fallback (no rule, tailnet down, image missing, login expiring, ledger unavailable)
   into a failed job with exit 3 and the reason.

5. Network: agent containers sit on the internal docker network `rmj-agents` (no route out) and reach the vendor only
   through `rmj-egress`, a CONNECT proxy that tunnels HTTPS to the harness's hosts and refuses everything else
   (`AgentHarness.egressHosts`; started by `rx-run.sh egress` before the login is staged).
6. Slots: a destination admits `agent_slots` agent runs at a time (default 2, 1...16), a lock `slots:N:<home>/rx/.agent-slot`
   taken before the checkout lock, so agents never use build slots.
7. Visibility: on the box Claude runs with `--output-format stream-json`; the Mac turns the events into readable lines
   (`AgentStream`) before the log archive and the panel see them. Codex prints its own progress.
8. Agent containers keep no docker log (`--log-driver none`, attached by the waiter); the box log passes through a redaction filter (login tokens become `[redacted]`), and the staged login destroys itself
   after 10 minutes if the run never starts. The waiter keeps the checkout locked after the container ends until the Mac
   has pulled the result (`unsecret` releases it, or 10 minutes pass), so a queued run cannot sync over the files first.

## The GitHub side

`gh auth token` is the credential (the owner's logged-in `gh`); RMJ stores none of its own. Runs
and jobs come from `GET /repos/{owner}/{repo}/actions/runs?per_page=50` and the run's jobs, with
ETags; runners from `/repos/{owner}/{repo}/actions/runners` and `/orgs/{org}/actions/runners`
(the org call needs the PAT with the org permission, taken from the Keychain, read-only use).
Queue reason: the registrations for the job's labels, classified as stale (offline, idle), all busy,
none online, or dispatch delay. Rerun: `gh run rerun <id> [--failed]`.

## Log streaming

Optional (docs/LOG-STREAMING.md). `RunEngine` opens a `LogStream` per run when `LogStreamer.make` finds an
enabled sink that accepts the run's tenant (none: nothing is created). `OutputPump` feeds the displayed
bytes to the stream; `LogLineAssembler` cuts lines, strips escapes and `LogShipper` redacts and appends
batches to each accepted sink's `LogSpool` (`~/.rmj/spool/<id>/`, atomic `.batch` files). A
`LogSinkDrainer` per sink sends the oldest file through `LogSinkFormat` (Loki, Datadog, Elasticsearch
encoders) and deletes it after a 2xx; a flock on the spool makes one drainer at a time, whether in the
CLI (while the run lasts, plus 3 s) or in the app (`AppBackground`, every 5 s). Status goes to
`~/.rmj/log-sinks.json`, read by the panel glyph and by `rmj sinks`. Failed GitHub job logs are shipped
once archived (`LogStreamerArchive`). Secrets: Keychain `rmj.sink.<id>`.

## Keychain

Items `rmj.pat.<target>` (one per runner target), created from Settings > Destinations with the
PAT pasted once, readable by the app and the CLI (same signing identity, access group), never
exported. No file on a box holds a PAT: a deploy sends the values on the stdin of the ssh command that runs
`docker compose build/up/rm`, whose first step reads and exports them for that process alone, so compose
interpolates them into the runner containers' environment (the generated file says `${GH_PAT_X:?run through rmj}`,
so a manual `up` on the box fails loudly). `entrypoint.sh` unsets the PAT before a job runs; Docker keeps it in the
container config, so restarts and reboots work with the Mac off. The box keeps `.rmj-credentials`, the sha256 of
the values last handed over, which is how a rotated PAT is seen; a deploy also removes a `.env` an older RMJ left.
The streamed output of the deploy is scanned for the PAT values and redacted before it reaches the panel, the log
or the ledger.

Measured 2026-10-27 with `scripts/keychain-check.sh` (ad hoc signed bundle, an update simulated by
re-signing both binaries with an empty entitlements blob: a new cdhash, same identifier and certificate): before the update the CLI that wrote an item reads
it and the app binary it named as trusted does not; after the update neither reads it. macOS answers
"authorization failed" where it would show the allow/deny dialog, which no headless process may
show. D7 therefore holds: only the app, which can show the dialog, reads a PAT from the Keychain,
and the CLI gets the value through `PatHandoff` (a file in `~/.rmj/handoff`, mode 0600, valid 60
seconds, taken once). Reads never prompt: the process turns the keychain dialog off.
