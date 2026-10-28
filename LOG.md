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
