# RMJ architecture

## Targets

```
Package.swift            swift-tools-version 6.0, macOS 14 deployment target, no dependencies
Sources/RMJCore/         everything testable; imports Foundation, Darwin, Security (Keychain),
                         SQLite3; never SwiftUI or AppKit
  Net/                   TailnetState (tailscale status --json), DestinationProbe, SSH (argv builder,
                         fixed options, address verification), Rsync
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
  Agent/                 MCPServer (JSON-RPC over stdio), Tools, Redaction (escapes, invisible Unicode)
  Release/               RMJRelease (standing, canUpdate), ReleaseCheck
  Support/               ProcessRunner, Executables, RMJHome, Clock, SafeFile, Keychain
Sources/RMJ/             SwiftUI app: RMJApp, AppStore, PanelView, JobsTab, DestinationsTab,
                         RoutingTab, HistoryTab, SettingsView + panes, MenuBarIcon, Theme, Looks,
                         Components, Updater, LoginItem, Notifier, DemoShots
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
| GitHub runs and jobs | 15 s | 120 s |
| GitHub runners | 60 s | 10 min |
| Local log tail (one running rx job) | streaming | none |

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
   settle from `.rc` and `.meta` (`done` or `failed`).
4. Local: run the argv (or `bash -c` in `--shell` mode) with the Mac's environment, location
   `local` with the reason and `environment: mac`, same streaming, same ledger, log written to the
   archive directly.
5. Cancel: `docker rm -f` by label over ssh (or SIGTERM then SIGKILL locally); the waiter records
   `cancelled`.
6. Reconcile (every `rmj` invocation, app launch, wake, 60 s while a job is `running` or `lost`):
   per online destination, read `.launch`, `.rc`, `.meta`, container presence and `boot_id` for
   each open job; settle, or mark `lost: destination rebooted` with the partial log; retry
   pending log pulls.

## The GitHub side

`gh auth token` is the credential (the owner's logged-in `gh`); RMJ stores none of its own. Runs
and jobs come from `GET /repos/{owner}/{repo}/actions/runs?per_page=50` and the run's jobs, with
ETags; runners from `/repos/{owner}/{repo}/actions/runners` and `/orgs/{org}/actions/runners`
(the org call needs the PAT with the org permission, taken from the Keychain, read-only use).
Queue reason: the registrations for the job's labels, classified as stale (offline, idle), all busy,
none online, or dispatch delay. Rerun: `gh run rerun <id> [--failed]`.

## Keychain

Items `rmj.pat.<target>` (one per runner target), created from Settings > Destinations with the
PAT pasted once, readable by the app and the CLI (same signing identity, access group), never
exported. Deploy writes `.env` on the box over ssh from a template with the values substituted in
memory and sent on stdin, mode 600; the streamed output of the deploy is scanned for the PAT values
and redacted before it reaches the panel, the log or the ledger.

Measured 2026-10-27 with `scripts/keychain-check.sh` (ad hoc signed bundle, an update simulated by
re-signing both binaries with an empty entitlements blob: a new cdhash, same identifier and certificate): before the update the CLI that wrote an item reads
it and the app binary it named as trusted does not; after the update neither reads it. macOS answers
"authorization failed" where it would show the allow/deny dialog, which no headless process may
show. D7 therefore holds: only the app, which can show the dialog, reads a PAT from the Keychain,
and the CLI gets the value through `PatHandoff` (a file in `~/.rmj/handoff`, mode 0600, valid 60
seconds, taken once). Reads never prompt: the process turns the keychain dialog off.
