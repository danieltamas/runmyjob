# LOG

## 2026-10-27 - spec

- Name decided by the owner: RMJ, Run My Job; `rmj` is also the CLI for agents.
- Written: AGENTS.md, docs/PLAN.md (U0..U13, complete-when, measured-by, quality criteria, D1..D5),
  docs/ROUTING.md, docs/ARCHITECTURE.md, docs/DESIGN.md, docs/AGENT-API.md, SECURITY.md, README.
- Reference implementation that works today and that RMJ absorbs: `~/agent-os` commits 4e1fc7a
  (rx), 5dcba72 (guard), 07c813d (fleet-runners), all on main, not yet pushed.
- Facts that shaped the spec, all from 2026-10-27 on ai-eu-1: a atlas job queued 10 min
  behind a stale offline runner registration (U5 queue reason, U6 prune, the entrypoint sweep); the
  box froze 14:43-14:49 under a cold Rust build and the job showed failure with its step still
  running (U6 heartbeat, `lost` state); `cargo test -p <crate>` rebuilt bundled DuckDB for 18 min
  into a second build hash (warm/cold in History); an rx client killed at 600 s left a running
  container and no log until the box-side waiter existed (the rx contract's `.rc`/`.meta`/`.log`);
  twelve exited rx containers in Dozzle (containers never kept for visibility, logs instead).
- Codex review of the spec (docs/reviews/2026-10-27-codex-spec.md): 60 findings, 7 P0, 33 P1,
  20 P2. Folded in, same day:
  - P0: tenant classification (explicit repos table, `unclassified` routes local, never
    `personal` by default); ssh bound to the verified peer address with proxies and multiplexing
    disabled, rsync the same; argv preserved end to end with an explicit `--shell` mode; a launch
    record so exit 125 from a started command is never rerun locally; a per-worktree lock held by
    the box-side waiter from sync to container end (also fixes the ledger lock); the registration
    sweep restricted to this stack's own names, this box's label, older than 10 min (also shipped
    to the agent-os entrypoint, commit bfcdce8).
  - P1: location and fallback reason separate from lifecycle state; `environment: mac` for
    reduced verification; ULID before dispatch and in every remote name; memory budget per
    destination; streaming to the box log from the start plus boot-id based reboot reconcile;
    cancellation and detachment defined; timing provenance and monotonic elapsed; job-level
    GitHub timestamps, attempts and conclusions; every completed run's log archived on both
    sides with pending pulls and retries; retention from completion with active rows exempt;
    size caps; redaction before persistence; cross-process SQLite contract; the guard rewrites
    local-routed commands too so fallbacks are recorded; GitHub routing shown as label mapping,
    not app-controlled; pagination and backfill; rerun bound to repo and run; peer by node ID;
    wake handling; probe freshness before dispatch; disruptive runner operations gated with
    Drain; `cargo build` rule first; the ledger profile transcribed and tested; rows with branch,
    worktree, current step, last-output age, visible Log and Rerun on failures; queued
    observations; destination capacity and readiness.
  - P2: queue causes as observations; separate idle and active poll bounds; remote `.env`
    lifecycle; Keychain sharing proven in U0 (D7); MCP switch scope stated; MCP schemas,
    pagination, caps and pinned versions; shims limited to `cargo` and `just`; contextual guard
    cases; rules validation and atomic save; runner version and readiness; wrapping rules;
    per-action availability and stale markers; explain inputs; Restart and Quit; acceptance and
    `/goal` for U11-U13; the live test uses `--to`; fault suite listed; JSON instead of TOML (D8);
    warmth only from an explicit cold marker.
  - Declined, with reasons: transactional capacity reservation (one owner, two boxes; a
    best-effort count plus a memory budget is enough, and a wrong guess only means a slower
    build); a box-side timer for pruning (no agent or timer on boxes is a principle; an idle box
    keeps 30 days until the Mac touches it, documented); attempt history beyond a parent link
    (not needed to see what ran and reruns are rare); timeline charts in History beyond the day
    strip (sortable rows first; charts when the data exists).
  - P3 (13 findings) left for the units they belong to.

## 2026-10-27 - U0 skeleton (branch u0-skeleton)

- Built: Package (3 products, macOS 14), RMJCore Support (ProcessRunner, Executables, RMJHome,
  Keychain, KeychainProbe, PatHandoff), minimal app and CLI, theme/components/settings parts from
  MacMax, scripts (bundle, check, install-from-source, make-signing-identity, render-icons,
  keychain-check), install.sh, CI. UpdateController is not ported (U11, it needs the panel model).
- Verified 2026-10-27: `scripts/check.sh --scratch ~/.cache/rmj-build` exit 0 (30 tests: 21 U0 plus 9
  PatHandoff, Codex-authored, hashes unchanged); `scripts/keychain-check.sh` on build/RMJ.app, ad hoc:
  before an update the CLI reads what it wrote and the app does not; after, neither does. Verdict
  "not shared": D7 fallback (PatHandoff), see docs/ARCHITECTURE.md, Keychain. The script exits 0 on a
  conclusive verdict. Not run against /Applications (install-from-source not run) or with an "RMJ Local"
  identity (make-signing-identity.sh not run; it imports into the login keychain).
- Codex review: docs/reviews/u0-2026-10-27.md. The last round still lists 3 P2 items, declined with
  reasons there (ProcessRunner limits go to U4; same-user races).
- Test files: PatHandoffAcceptanceTests needed two inner `try` (Codex fixed after the owner released a
  stale axon claim).
- Owner accepted U0 as is on 2026-10-27: D7 fallback stands (keychain-check verdict "not shared"), the three declined P2s stand. Carry to U4: ProcessRunner session escape and an output cap.

## 2026-10-27 - U1 tailnet state and destination probe (branch u1-tailnet)

- Built: Core Net - TailnetState (parse + read, RMJ_TAILSCALE_FIXTURE), TailnetMonitor (10 s active / 60 s idle, wake,
  maxAge), DestinationResolver (peer by ID, tailnet address ranges, literal IP rules), SSH argv and rsync -e, DestinationProbe
  (one ssh call: docker, rsync, images, labelled containers with stats, cores, memory, load, boot id, clock offset).
- Verified 2026-10-27: `scripts/check.sh --scratch ~/.cache/rmj-build` exit 0 (61 tests); `RMJ_LIVE=1 swift test --filter Live`
  probes ai-eu-1 online at 100.79.69.60 with docker 29.9.0, rsync 3.4.1, images, runner containers; Codex final review
  NO FINDINGS (docs/reviews/u1-2026-10-27.md).
- Open: ProcessRunner output cap (U4). Acceptance tests: 14 original + 16 added by Codex after the wire-format change.

## 2026-10-27 - U2 ledger store, retention, log archive (branch u2-ledger)

- Built: Core Store - Database (SQLite actor, WAL, busy_timeout 5 s, BEGIN IMMEDIATE), Schema v1 (job, job_event,
  destination_sample, runner_registration, log_archive, schema_version), Ledger (forward-only advance with the precondition
  in the UPDATE, events by own time, fill for reconcile), LogArchive/LogWriter (redaction across chunks, 50 MB cap with
  marker, 2 GB quota, .part then atomic rename), LogPull (pending until a pull succeeds), Retention (30 days, 7 days for samples).
- Verified 2026-10-27: `scripts/check.sh --scratch ~/.cache/rmj-build` exit 0; 13 U2 acceptance tests (Codex-authored,
  hashes unchanged); Codex review NO FINDINGS (docs/reviews/u2-2026-10-27.md).
- Open: the app's DispatchSource watcher of the ledger file (U7); the destination_sample and runner_registration write APIs
  arrive with the units that fill them (U4, U6).

## 2026-10-27 - U3 rules file, router, explain, capacity (branch u3-router)

- Built: Core Routing - Rules (Codable, strict keys, duplicate-key and semantic validation), RulesStore (load fails closed,
  atomic save with fingerprint check), RepoIdentity/Tenancy/CommandWords, Router with explain, `rmj route` in the CLI.
- Verified 2026-10-27: `scripts/check.sh --scratch ~/.cache/rmj-build` exit 0; 28 U3 acceptance tests (Codex-authored,
  hashes unchanged); `rmj route -- cargo test` in ~/Sites/axon prints ai-eu-1 (live probe, twice); `cargo build` routes
  local by rule; Codex review NO FINDINGS (docs/reviews/u3-2026-10-27.md).
- Open: profiles and the ledger probe cache (U4); the app's rules editor (U7/U8).

## 2026-10-27 - U4 `rmj run`, box script, sync, reconcile, cancel (branch u4-run)

- Built: Core Run - RunEngine (ULID row first, route, lock, sync, launch record, streaming, local fallback, settle), BoxClient/SSHBoxClient
  talking to Support/box/rx-run.sh (embedded as BoxAssets.swift by scripts/gen-box-assets.sh; check.sh fails when stale), DockerPlan with
  profiles (ledger), TreeSync, Reconciler (reboot, unreachable x3, vanished, abandoned), cancel, LogSanitizer, AgentContext;
  `rmj run|jobs|cancel`. Ledger gained tenant/worktree/branch/commit/dirty/agent/session and `relocate`. ProcessRunner: output cap, stdin.
- Verified 2026-10-27: `scripts/check.sh --scratch ~/.cache/rmj-build` exit 0 (128 tests; 26 U4 acceptance tests Codex-authored, hashes unchanged);
  `RMJ_LIVE=1 swift test --filter Live` green against ai-eu-1 (cargo check, client task death + reconcile, cancel < 10 s, lock wait);
  `rmj run -- cargo check` in ~/Sites/axon: done, exit 0, location ai-eu-1, complete row (sync, box and Mac times, clock offset, log available,
  agent claude-code); same from crates/axon-core with `-p`.
- Spec changes: ssh multiplexing over RMJ's own sockets (was ControlMaster=no); U0 keychain tests opt-in (RMJ_KEYCHAIN=1); check.sh allows the macmax repo slug.
- Open: the last review finding (no-ledger fallback output) fixed but not re-reviewed; deferred items in docs/reviews/u4-2026-10-27.md; the ledger profile is untested against the dev pair; ledger probe cache
  (destination_sample) still unwritten (clock offset comes from the box's own clock instead); live concurrent-lock acceptance via the shipped rules (no rule has a lock besides ledger).

## 2026-10-27 - U5 GitHub runs, jobs, queue observation, rerun (branch u5-github)

- Built: Core GitHub - GHCLI (`gh api -i`, token per call, org PAT via GH_TOKEN), GitHubPoller (watched set, 30-day backfill, gap, ETag, pagination, 403 pause until reset
  persisted, per-attempt rows with markers, 15 s / 120 s intervals), GitHubMapping (skipped is not failed, timed_out is failed), QueueAnalysis (observation, cause only when
  exactly one fits), GitHubRerun (`gh run rerun <id> -R repo [--failed]` as argv, superseded attempts refused), GitHubRouting (label mapping, mismatch); `rmj github poll [--repo] [--watch]`,
  `rmj rerun <id>`, GitHub step and observation in `rmj jobs`. GitHub rows are excluded from rx reconciliation.
- Verified 2026-10-27: `scripts/check.sh --scratch ~/.cache/rmj-build` exit 0 (143 tests; 15 U5 acceptance tests Codex-authored, hashes unchanged; two expectations rewritten by Codex after a
  macro mis-expansion); read-only live poll of danieltamas/axon with a throwaway RMJ_HOME: first poll 64 runs / 508 jobs (2 min, sequential `gh` calls), second poll 2 s with no new runs, no new events.
  No rerun and no call to any atlas or ledger repo was made: the "atlas rerun" part of the /goal was replaced by this read-only check on the owner's instruction.
- Open: the live queued-job path (current step, observation) is covered by the fake-API tests only; Settings UI for the PATs (U8); GitHub log fetching; review declines in docs/reviews/u5-2026-10-27.md.

## 2026-10-27 - U6 destination operations (branch u6-ops)

- Built: Core Ops - OpsShell (ssh + rsync, secrets on stdin), RunnerStackDeployer (dry report, atomic .env mode 600, compose build/up, redaction, busy and PAT checks), RunnerOperations
  (start/stop/restart/recreate refused while busy naming the job; drain; cancel), RegistrationPruner (shape, label, offline, idle, >10 min, revalidated before each delete), Heartbeat (3 failures, wake reset, once),
  DestinationOnboarding (checks with hints, writes only when all pass), RunnerImages; GitHubRunners/GitHubWriteAPI; vendored Support/runner-stack; `rmj destination report|prune [--preview]`.
- Verified 2026-10-27: `scripts/check.sh --scratch ~/.cache/rmj-build` (161 tests; 18 U6 acceptance tests Codex-authored, hashes recorded; one compile fix applied as a Codex patch);
  live read-only on ai-eu-1: `rmj destination report` -> "deploy: no-op", runner-acme/ledger/atlas running version 2.338.2, images gh-runner:2.338.2 and rx-rust:latest;
  `prune --preview` listed one stale candidate (acme/atlas bf459794a71f-1793112347) and deleted nothing. org:Acme preview needs the Keychain PAT (403 without it). Nothing was deployed, restarted or deleted.
- Open: second review round fixes not re-reviewed; deploy CLI, PAT rotation, Settings UI, stack embedding in the bundle.

## 2026-10-28 - U7 panel, Settings, Destinations setup (branch u6-ops, uncommitted)

- Built: Core Panel (presentation, DemoShots, BoxInventory, LogTail, PanelLoader); app panel (Jobs, Destinations, Routing tabs in the Bton-style tab island, menu bar icon states, footer),
  Settings window (General, Tailscale, Destinations, Hooks/Notifications/Agent placeholders, Retention, About); Tailscale box inventory (OS from `tailscale status`, RAM/disk/OS release from the
  5-minute probe over the tailnet); `DestinationSetup` (prerequisites, rx images, runner stack with Keychain PATs, registration check; idempotent) behind the Add wizard, "Set up / repair" and
  `rmj destination setup <name>`; bundle.sh ships runner-stack and box images; tenant check of runner targets in rules validation.
- Verified 2026-10-28: `scripts/check.sh` green, 188 tests (U7 acceptance by Codex: 15 panel/layout, 12 setup; hashes unchanged; two Codex tests corrected by Codex after evidence: 71-char string, AX tree).
  Security + QA subagent reviews and a Codex read-only review (docs/reviews/u7-2026-10-28.md); fixed: failure badge marked seen while panel closed, multi-target registration check, PAT stored only after checks pass,
  single-save onboarding with targets, tenant check of runner targets, CWD never searched for support files, silent `docker compose build` failure, log tail refresh at settle, panel probes off the poll loop.
- Not exercised: no real setup, deploy or probe-with-new-fields against any box (live tests skipped); UI not exercised live by the owner.
- Open (from reviews, not fixed): runner readiness on cards is container presence, not GitHub registration; GitHub label mapping
  by repo target not by label; setup Close/cancel is held while running; PAT add/rotate UI after the wizard;
  no tenant-check acceptance test yet (Codex to author); owner approval of renders pending.

## 2026-10-28 (later) - U7 UI feedback round
- Buttons: one ActionButton (28 pt capsule; filled only for the single primary) behind PillButton, ChipButton and ModalFooter.
- Routing tab: rule cards are two lines (name + chain, match); opening a rule edits it in place (RuleEditorCard: save, delete, move, add rule) through RuleEditing; the explain card is "Where would it run?" with a description.
- Jobs: GitHub rows no longer show the cat glyph.
- Verified: swift test 188 passed, scripts/check.sh ok, renders inspected, installed.
- Done afterwards: durations now `2m 46s` (PanelFormat, DESIGN.md); Codex updated PanelAcceptanceTests after the stale Axon claim of its earlier session was released (axon bus release); 188 tests, check ok. (Superseded: durations as "2m 46s" (owner request) NOT applied: the Codex-authored tests hardcode "6 m 15 s" etc. and Codex was blocked by an Axon claim held by its earlier sessions. Needs the owner to release the claim or approve a test edit; PanelFormat change is 3 string literals.)
- Runner list is dynamic (owner feedback): runner services come from the destination's runner_targets. The bundled compose keeps its tuned services (ledger, atlas, acme); any other target gets a generated service in docker-compose.rmj.yml (RunnerCompose), written with .env, and `up -d` names only the configured services. The compose guard that rejected unknown targets is removed. The PAT prompt asks once per GitHub owner. Tests: RunnerComposeAcceptanceTests, RuleEditingAcceptanceTests (Codex); 202 pass.
- 2026-10-28 (round 3): History tab (settled jobs 2-30 days, 200 max), preset-based rule editor (What / Where / repos, More for the rest), New rule as the floating pill, "Test your rules" folded under the rules, runner readiness from GitHub registrations (name `<id>-<digits>`), GitHubRouting enforces the tenant boundary on its own, PAT rotation sheet (Tokens), More apps pane (Bton, MacMax, Axon, Cloak, run.dev), real RMJ logo in the panel header, README rewritten with Tailscale setup and the tailnet-only rationale. 219 tests, check ok.
- Open: agent hooks (U9) are not built: nothing yet redirects an agent's cargo/just to RMJ except explicit `rmj run`; Bton detection belongs there.


## 2026-10-28 (U9) - hooks for every harness
- Built: `rmj hooks install|status|remove [harness]`, `rmj guard` (Claude Code PreToolUse hook mode with `--hook`, plus `--command/--cwd`), `cargo`/`just` shims for Codex, OpenCode and Hermes (those harnesses' own hooks need user trust, so RMJ only ships shims), Settings > Hooks status. Bton and the old agent-os guard are detected, not required. Also live release checks on More apps, repo picker in the rule editor, History pagination, demo names in renders.
- Review: Codex read-only, 9 findings (2 P1, 7 P2), all fixed; docs/reviews/u9-2026-10-28.md. Re-probed by CLI: leading space, env prefix, `rmj run ...; cargo test`, `<<-` heredoc, RX_LOCAL, commit message mentioning cargo test, non-object hooks value left untouched.
- Verified: swift test 241 passed, scripts/check.sh ok, app reinstalled. Temp-HOME smoke test: install/remove idempotent, other hooks preserved.
- Open: the real ~/.claude/settings.json was not touched (owner runs `rmj hooks install`); agent-os link.sh still installs the old guard (disable it to avoid double guarding); guard routes by tenant ownership, not per-rule repo lists; shipped default rules still carry the owner's real names; no second Codex pass on the fixes (only re-probed).

## 2026-10-28 - no owner config in the source
- A fresh install now starts from an empty starter (Rules.starterJSON); the former default fleet rules live in the test fixture and in the owner's ~/.rmj/rules.json. Built-in tenant names and tenant colours by name are gone (colour is derived from the name). The guard allows a classified repo that no rule names. Tab switches no longer animate the whole tab content. 245 tests, check ok.
- Open: the bundled `ledger` profile (BoxAssets, Support/box/profiles) and the runner-stack compose services for ledger/atlas are still the owner's; they need a user profile directory (~/.rmj/profiles) and a generated compose.
- 2026-10-28 (no owner config in the repo): profiles are user files in ~/.rmj/profiles (ProfileStore), the bundled runner compose holds no services (all generated from runner_targets), Dockerfile.rust and the ledger profile are gone, the tenant deny is configured (`shared: true` marks a non-company tenant) instead of hardcoded names, docs/tests/fixtures use acme/globex/ledger/atlas. The owner's real rules.json and profiles live in ~/.rmj. 250 tests, check ok.

## 2026-10-28 (U10) - agent API
- Built: Sources/RMJCore/Agent (AgentAccess, MCPServer, tools, schemas, AgentCLI), `rmj mcp` (stdio), `rmj job|log|failures|destinations|runners` and `rmj jobs` with filters and `--json`, Settings > Agent access (switch plus the `claude mcp add` line). Acceptance tests by Codex: AgentAPIAcceptanceTests, AgentAPILogTests (hashes unchanged).
- Review: Codex read-only, 2 P0 and 7 P1/P2; fixed or answered in docs/reviews/u10-2026-10-28.md.
- Verified: swift test 265 passed, scripts/check.sh ok; stdio smoke test with a temp RMJ_HOME: initialize, access off -> isError, access on -> data, `rmj jobs --json`.
- Open: `rmj log --pull`, `destinations --probe`, `runners --prune` are not built (the doc no longer lists them); capacity and runner figures in `destinations` stay null until a probe cache exists; route over MCP takes no live probe.

## 2026-10-28 (U11) - notifications and release check
- Built: Sources/RMJCore/Notifications (JobNotice, NotificationSettings, NotificationPlanner), Releases/UpdateChecker, Support/ConfigFile (locked read-merge-write, shared with AgentAccess); app side AlertCenter (UNUserNotificationCenter, "Open log" action), Notifications pane switches, header update arrow, About status and Update button (opens the release page).
- Review: Codex read-only, 2 P0, 6 P1, 1 P2; fixed or answered in docs/reviews/u11-2026-10-28.md.
- Verified: swift test 279 passed, scripts/check.sh ok, jobs-update render shows the arrow, app reinstalled. One Codex test line (an unsatisfiable `#expect(!(a ?? "").contains(b))`) was fixed by Codex, hashes re-recorded.
- Open: an ssh-only failure on an online peer does not raise the unreachable notice; the in-place updater waits for U12; the arrow against a live GitHub feed needs the public repo.

## 2026-10-28 (U12 prep) - release scripts
- Built: scripts/release.sh (ad hoc, reproducible, --verify), acceptance.sh (steps 1-6), mcp-smoke.py, perf.sh, tap.sh, release-verify workflow, docs/RELEASE.md. Idle polling: one ledger read per snapshot, `tailscale status` every 30 s while nothing runs.
- Verified: `release.sh 0.1.0 --verify --ref HEAD` two builds identical; `acceptance.sh mcp` ok (8 tools, slowest 43 ms).
- Open: idle CPU measures 0.43% over 120 s against the 0.3% budget (streaming 0.33% against 2%); live, the 10-minute perf run, the public repo, tag, cask and release are not done. No Developer ID: ad hoc signing only.

## 2026-10-28 (registry) - More apps from the registry
- Built: Sources/RMJCore/Registry (decoder and rules, store, icon check, refresh rule, download; ported from MacMax), Sources/RMJ/MoreAppsModel.swift, MoreAppsPane on the registry (RMJ's own id "rmj" dropped), Support/Registry snapshot (scripts/registry-snapshot.sh, registry commit in Support/Registry/COMMIT) shipped by bundle.sh; the hard-coded list, its ReleaseFeed calls and Support/MoreApps are gone.
- Tests: Codex ported MacMax's two registry suites and added the CONSUMER.md acceptance lines; 304 tests pass unchanged.
- Release ping and confirmation added as the last step of docs/RELEASE.md (repository name runmyjob). Never run: there is no release to check it against.
- Docs: README, SECURITY (network), PLAN non-goals, ARCHITECTURE.

## 2026-10-28 - fixes after use

- Local runs whose `rmj run` client died stayed `running`: a client pid file plus a 30 s reconcile now settles them as `lost` after a 60 s grace.
- The rule editor widened the panel: Up/Down are icon-only; `RuleEditorLayoutTests` pins the width at 404 pt.
- GitHub rows had a Log button but nothing ever archived a GitHub job log: the button now runs `gh run view --job <id> --log` into `~/.rmj/logs/<id>.log` (redacted, capped). Archiving on completion for failed jobs (PLAN.md) is still open.
- Evidence: 317 tests pass, `scripts/check.sh` ok.
- Failed GitHub jobs are now archived automatically by the app's background loop (3 per round, once per job; a failed fetch stays pending). 317 tests, check ok.
- Machine cleanup (agent-os, uncommitted there): `rx` is a forwarder to `rmj run`; the old build guard and its tests are gone; CANON and rules/remote-build.md point at RMJ. Open: `rmj hooks install claude-code` (owner), then debug.
- Idle CPU: the panel loop now beats every 15 s when the panel is closed and nothing runs (5 s open, 1 s running); the failed-log archive runs once a minute. perf.sh 240 s: idle 0.29% (budget 0.3%), streaming 0.40%. The full 600 s run is still to do. `brag-output/` and `runmyjob.mp4` are git-ignored.

## 2026-10-29

- Job card redesign (context line, command well, local CPU/memory gauges), detail with phase bar and property rows, no inline log; one hover tooltip with the run's moments in its own window; even tab island; rows open on their own state; destination and job cards slide open (no fade).
- Local runs record average CPU and memory (`LoadRecorder`, schema v2: `avg_cpu`, `avg_memory_bytes`); shown on finished rows. Box runs are not measured.
- Settings > Destinations > Tokens now edits a destination's repo and org targets as well as its PATs.
- Routing tab: Test your rules first, workflows seen collapsed, tenant deny as a footer.
- Idle CPU budget relaxed from 0.3% to 0.4% (owner's call); perf.sh 300 s on this build: see the line below.
- perf.sh 300: perf: idle 0.24% over 300s (budget 0.4%)

## 2026-10-29 - release 0.1.0

- First public release: the menu bar app and `rmj` CLI. Routing of builds and tests to your Tailscale boxes with a local fallback, one Jobs list over 30 days with search and filters, Destinations with runners and capacity, Routing rules with a "Test your rules" dry run, GitHub job logs archived on demand and after failures, notifications, updater.
- Local runs record their average CPU and memory. Box runs are not measured yet.
- Ad hoc signed, reproducible build; no Developer ID, so a browser download is blocked on first open (install.sh and the cask fetch it without the quarantine flag).
- Pending: the second company (s1) scenario; `live` against a real box was not run for this release; the manual check of a failed job's log opened from its notification is not recorded.

## 2026-10-29 - required programs per box

- Why: remote `scripts/review-pr.test.sh` and part of `wt.test.sh` failed on `ai-gamerina-eu` with exit 127: the box has no zsh (`command -v zsh` empty), the tests call it. RMJ routed correctly; the box lacked a program nothing checked.
- New destination key `requires` (rules.json, `docs/ROUTING.md`): the programs and shells a box must provide. Validated as plain names, no duplicates. Setup checks each with `command -v` in the same ssh call as docker and rsync and fails with `missing on the box: zsh` plus an install hint.
- Acceptance tests (Codex): `RequiresManifestAcceptanceTests`.
- Open: install zsh on `ai-gamerina-eu` (`vboxuser` has no passwordless sudo; the owner runs it). The probe and the destination card do not show missing programs yet; only setup checks them.

## 2026-10-29 - release 0.1.1

- Destinations take a `requires` list of programs and shells the box must provide; Setup checks each and fails with `missing on the box: zsh` and an install hint (docs/ROUTING.md). Builds before 0.1.1 reject a rules.json that has the key, so update first.
- Pending as in 0.1.0: the second company (s1) scenario; `live` against a real box; the manual check of a failed job's log opened from its notification. The probe and the destination card do not show missing programs yet.

## 2026-10-29 - release 0.2.0

Optional log streaming, the Run report window, and no Open log button on a queued job. Details in the two entries below. Builds before 0.2.0 ignore the `log_sinks` key in config.json, so update first.

## 2026-10-29 - log streaming (0.2.0)

- Optional streaming of every run's output to Loki, Datadog or Elasticsearch/OpenSearch, several sinks at once (Settings > Log streaming, `rmj sinks`, docs/LOG-STREAMING.md). Each sink names its tenants or `all`; repo, branch, agent and destination travel with every line.
- A disk spool per sink holds what is not yet ingested and drains empty (256 MB and 7 days at most, kept while the sink is paused, backoff and `Retry-After` honoured, rejected batches set aside). A run never waits more than 3 s for a sink.
- A glyph in the panel header shows streaming is on (teal) or a sink is behind (amber). Keys are in the Keychain. GitHub runs are streamed only for failed jobs, once archived.
- Checked: acceptance tests by Codex (42 across config, format, spool, drainer, pipeline, streamer); `scripts/sinks-check.sh` streams a 650-line `rmj run` to local Loki and Elasticsearch receivers. Datadog is pinned byte for byte by unit tests, not by a live receiver (its intake host is fixed). Codex review: docs/reviews/log-streaming-2026-10-29.md (4 P0 and 6 P1 fixed or accepted with reason, the rest listed open). `scripts/check.sh` 394 tests, `sinks: ok`. Second round (security persona, adversarial QA): docs/reviews/log-streaming-2026-10-29.md. Also: Open log is hidden for a queued job. Not run: `perf` with sinks on, a real Loki/Datadog/Elasticsearch account, the Keychain read by the installed CLI.

## 2026-10-29 - run report window

- The Log button (and a notification's Open log) now opens a Run report window, like Settings, instead of the log in another app. Left: result, where, timing and resources of the run (exit codes, queue wait, sync, run, avg CPU and memory, clock offset) and log counts. Right: the log with line numbers, lines colored by meaning (commands, errors, warnings, passes), search, All/Errors/Warnings filter, Copy log, Reveal; a running job's log follows live.
- Terminal colors are stripped before display (logs are untrusted text), so colors come from what a line says (`LogClassifier`), not from the tool's own escapes.
- Model: `RunReport`, `LogDocument`, `LogClassifier` in RMJCore; acceptance tests by Codex: `RunReportAcceptanceTests` (13).
- Open: the report is shown for the ledger's data only; box jobs have no CPU and memory yet.

## 2026-10-29 - release 0.3.0

- Update in About now installs the new release in place, like MacMax and Bton: it runs the installer bundled in the app, quits RMJ and reopens it. A failure is shown in About and written to `~/.rmj/update.log`. Before, the button opened the release page.
- A glowing "Star on GitHub" button in the panel footer stars danieltamas/runmyjob with your own `gh` account, shows "Starring..." while it works, and is gone for good once starred (remembered as `starred_repo` in config.json, no check after that). It shows only when `gh` is logged in and the repo is not starred yet; it has no close button.
- The footer's poll ages use the GitHub mark and a server glyph instead of words.
- A run report for a job that printed nothing says so instead of showing an empty pane.
- Checked: acceptance tests by Codex for the star logic (`RepoStarAcceptanceTests`, 6); `scripts/check.sh` 400 tests. Not verified: the in-place Update replacing a running install from an older build, the star click against GitHub from the installed app.
