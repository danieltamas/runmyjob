# RMJ design standard

Set before any view is written. Every UI review checks the offscreen renders against this file and
the glitch list in MacMax's `docs/LESSONS.md` section 4. Foundations (`Theme`, `Looks`,
`Components`, the Settings parts) are copied from MacMax's current `main` and renamed; the three
looks stay (RMJ default dark double bezel, Solid Glass, Solid Glass Light). Type scale, motion
(springs only), custom glyphs and SF Symbols (never emoji) as in MacMax's DESIGN.md.

## One hue per meaning

| Meaning | Token | Used for |
|---------|-------|----------|
| Running | `running` | `syncing` and `running`, the menu bar count, the live elapsed |
| Done | `ok` | `done`, a reachable destination, an online runner |
| Failed | `crit` | `failed`, `lost`, an unreachable destination during a job, the menu bar badge |
| Waiting | `warn` | `queued` past 60s, a stale registration, a destination at capacity, a runner version near its deadline |
| Local | `local` | The location chip of a job that ran on the Mac, always with its reason |
| Offline or stale | `unknown` | Tailnet down, a peer offline, a failed probe, a measurement older than its poll interval; never green |
| Acme | `tenantA` | Tenant chip and destination card accent |
| Globex | `tenantB` | Tenant chip and destination card accent |
| Brand | `brand` | Accent, the active tab, selection; from the icon's gradient |

A state colour is never used for a tenant, a tenant colour never signals state, and `local` is a
location, never an outcome: a local job that failed is `failed` in `crit` with a `local` chip.

## The menu bar icon

The route glyph (`Brand/icon-menubar.svg`, decision D4) with states: idle (plain), running (the
glyph plus the count of running jobs, 1-9, then 9+), failed (a small badge until the Jobs tab has
been opened or the notification acted on), tailnet down (a slash through the glyph). Rendered at
18 points, tested in light and dark menu bars.

## The panel (MenuBarExtra, `.window`)

404 points wide; height `min(780, visibleFrame.height - 40)`. Top to bottom:

1. **Header**: the app glyph, "RMJ", the tailnet chip (`tailnet up`, `relayed`, `tailnet down`,
   `no client`, `key expires in 3 d`), the count of running jobs, an update arrow when a newer
   release is out, a gear that opens Settings.
2. **Tab island**: Jobs, Destinations, Routing. Badges: Jobs shows running plus queued in
   `running`; a failed job not yet seen adds a `crit` dot.
3. **Content**, scrolls; cards in a `RowStack`.
4. **Footer**: last poll age per source (`GitHub 12s`, `boxes 30s`, with the active and idle
   intervals in the tooltip), the GitHub rate budget when under 500, then Restart and Quit (MacMax
   LESSONS section 1). Quit with a remote job running says the job keeps running on the box and
   will be reconciled on the next launch; it never cancels.

## Text at 404 points

Single-line labels are the rule (Components). Long strings follow fixed wrapping rules, tested by
a layout test with a 48-character repo name, a 60-character workflow name, a 120-character
reason: the repo name is the row title and wraps to a second line before anything truncates; the
command or workflow line truncates in the middle (`cargo test --workspace ... --no-fail-fast`)
with the full text in the tooltip and the expansion; a reason wraps freely in the expansion and is
one truncated line in the row's meta.

## Jobs

Sections: Running, Queued, Today, Yesterday, Earlier: one list over the 30 days of the ledger, 25 rows at a time. A search field
(every word must appear in the repo, command, branch, worktree, commit, destination, state or id) and one chip of
All, Failed, Done, GitHub or Local narrow it; there is no separate History tab.

A row, two lines plus meta:
- Line 1: repo name (title), the location chip with the tenant colour (`ai-eu-1`, `local`,
  `github`), the agent glyph (Claude Code, Codex, OpenCode, Hermes, terminal, GitHub), on the
  right the state chip.
- Line 2: branch, worktree name (or `main checkout`), short commit, a `dirty` dot when the tree
  had uncommitted changes; then the command or `workflow / job`.
- Meta line, by state:
  - `syncing`: `syncing 12s`.
  - `running` (rx): elapsed (monospaced digits, once a second) and `last output 3s ago`; when the
    last output is older than 60s the age turns `warn`. The phase is indeterminate for an
    arbitrary command; no progress bar is drawn.
  - `running` (GitHub): elapsed, `step 3/7 cargo test`, `last output` from the job's log age.
  - `queued` (GitHub): `waiting 3 min`, the labels asked for, the observation
    (`0 online, 1 offline idle, observed 15s ago`) and the suspected cause when there is one
    (`stale registration bf45...`), else `cause unknown`; `waiting on 2 jobs` when it is a
    dependency wait.
  - `queued` (rx): `waiting for <job>` when a lock is held, `probing ai-eu-1` otherwise.
  - `done`: duration with provenance (`6m 15s, box`), warmth when known.
  - `failed`, `lost`, `cancelled`: outcome, duration, the fallback reason when local
    (`local: tailnet down`), `environment: mac` when the suite ran on the Mac (reduced
    verification), and two visible buttons: `Log` and `Rerun`. Not hidden in the expansion.
  - `skipped`: GitHub's conclusion as given.

Expanded row: the timeline (queued, sync, start, end as a thin bar with the sync segment
distinct), exact timestamps with provenance, box start and end when present, the clock offset,
the rule that matched (or the fallback reason in full), the session id, the log tail (last 40
lines, monospaced, escapes stripped, `Open log`, `pending` or `unavailable: <reason>` when it is
not local), `Cancel` for running jobs, `Rerun` (rx: the same argv on the same worktree, with a
note when the tree changed since or is gone; GitHub: a new attempt linked to this one), `Open on
GitHub`, `Explain route` which jumps to Routing with this job's inputs prefilled.

Empty state: "No jobs yet. Agents' `cargo test` and `just check` land here once the hook is
installed (Settings > Hooks)."

## Destinations

One card per destination, accent in the tenant colour. Header: name, tenant chip, roles (`rx`,
`runners`), state chip (`online`, `relayed`, `offline: peer offline since 14:43`, `unreachable:
ssh timeout`, `rejected: not a tailnet address`, `rebooted 10 min ago`, `tailnet down`). Body, in
order:
- Sensors: a row of tiny icon-and-value chips under the summary (CPU busy, memory used, load, disk
  used, download, upload; swap only when in use; temperature and fan only where the box exposes
  them). Open, each is a tile with its name and a sparkline of the last 30 minutes, followed by swap
  and CPU and memory pressure. A fan icon turns while a fan reports rpm. A VM, WSL or container
  box shows no temperature or fan chip at all, never an empty one. Tones: CPU, memory and disk warn
  from 85 percent and go critical from 95; load warns at one per core and goes critical at two;
  temperature warns from 80 C and goes critical from 90.
- Capacity: rx slots `1 of 3`, memory budget `14 of 36 GB` (rx limits plus runner caps), CPU
  count, 1-minute load, free memory. A job type the box cannot take right now says why
  (`over budget`, `no rx-node image`).
- Running containers: rx jobs (linked to their rows) and runner containers with their job, each
  with its CPU and memory from the last `docker stats` sample.
- Runners per target: version with its deadline when behind (`2.338.2, latest 2.340.0, served
  until 2026-11-20`), readiness (`registered`, `registration failed: <error>`, `PAT lacks
  permission`), online, busy, stale count with a `Prune` button that lists exactly what it will
  delete (shape, label, age) and asks once.
- Images with age, a `Rebuild` per image.
- Last probe time; every measurement older than its poll interval carries a stale marker and its
  last-success time.

Availability is per action, not per card: an offline card keeps `Prune` (GitHub, not the box) and
the links to cached logs, and shows the reason in place of the actions that need the box.

The Add card at the end opens Settings > Destinations > Add.

## Routing

Three groups, in this order:
1. The tenant deny, a fixed card, not editable here.
2. The rx rules as an ordered list: name, match summary, chain (destination chips in order,
   `local` last in `local` colour), image or profile. Reordering by drag; editing opens the rule
   in Settings with a form (match keys, chain, image, volumes, profile, cold marker). A rules file
   error replaces the list with the message and the path; a button opens the file; the last valid
   rules stay in force for routing and the card says so.
3. GitHub label mapping: each watched repo's workflows with their `runs-on` labels, the
   destination whose runners serve them, or `no destination serves these labels` in `warn`.

The explain field at the top: a command and a repo, defaulting to the last job's (`from job
<id>`), or typed (`hypothetical`); the answer lists the inputs used (repo and how its tenant was
resolved, worktree, command words, files checked, tailnet state and age, each destination's
probe age), then the chain line by line (`ai-eu-1: online 20s ago, 1/3 slots, 14/36 GB,
rule "cargo repos" -> chosen`), every skipped destination with its reason, the matched rule, and
the result.

## Settings

Panes, each a `SettingsCard` per group, labels left, controls right (MacMax LESSONS section 5):

- **General**: look, start at login, show elapsed in the menu bar.
- **Tailscale**: state, the client path, the peers RMJ uses with their node IDs; when the state is
  not `running`: "Every job runs on this Mac until the tailnet is up." and an `Open Tailscale`
  button.
- **Destinations**: the list, Add (the probe flow with each check as a row: peer online, address
  verified, ssh, docker, rsync, images, home; each with its fix hint), Edit, Remove (asks once;
  removes from `rules.json`; a PAT is never on the box to clean up), the
  runner stack per destination (deploy, targets, which PATs it holds, start, stop, drain,
  recreate when idle), rotate a PAT (saved to the Keychain; the next deploy of each destination hands it to the runners, and a deploy dry run says `credentials` changed).
- **Hooks**: a row per harness (Claude Code, Codex, OpenCode, Hermes): `installed`, `not
  installed`, `not present on this Mac`, `shims only (cargo, just; scripts/check.sh not covered)`
  with Install and Remove.
- **Retention**: 30 days (fixed in v1, shown), log folder size and count against the 2 GB cap,
  `Prune now` (local and every reachable box), pending pulls.
- **Notifications**: failed or lost job (on), destination unreachable during a job (on), job done
  (off).
- **Agent access**: the switch for `rmj mcp`, the `claude mcp add rmj -- ~/.local/bin/rmj mcp`
  line with a copy button, what agents can read (read-only, logs redacted), and the note that the
  switch governs MCP only (AGENT-API.md).
- **About**: version, build, the installed source commit, Update, links (README, issues,
  SECURITY), licence.

## Screenshots

Rendered offscreen from `DemoShots` data (two destinations, one of each tenant, a running rx job
with branch and last-output age, a running GitHub job on step 3/7, a queued runner job with a
stale-registration observation, a failed job with Log and Rerun visible, a local fallback because
of a peer offline, a lost job after a box reboot, a history of 30 days with one cold run), per
MacMax's `docs/SCREENSHOTS.md`. The README uses only these renders.

## Components and the standard

Every control comes from Sources/RMJ (Components, Interaction, SettingsParts, Modal); a view never styles its own.

- **Buttons:** `PillButton` is the one main action of a surface (filled when prominent); `ChipButton` is every other action, in rows, cards and footers (red when destructive); `LinkButton` only for text that goes somewhere; `IconButton` for a glyph. All use `PressStyle`: pointing-hand cursor over the whole hit area, a lift on hover, a sink while pressed, 40% opacity when disabled.
- **Modals** are `ModalFrame`: title, one line on what it does, the content, then `ModalFooter` with the way out (Cancel, Done) left of the main action, both right-aligned in one row. A modal waiting on work shows no Cancel and no Done until it ends.
- **Fields:** `FieldBlock` (label above, hint below) around `GlassField` or `SecretField`. The system text field style is never used.
- **Results:** `StatusLine` (outcome in its hue, then the fix hint in the secondary text). One hue per meaning: ok green, changed or running teal, failed red, warn amber, unknown grey.
- **Numbers:** durations as `12s`, `6m 15s`, `1h 2m` (PanelFormat); sizes in GB with one decimal under 100; counts in a grey capsule, lit in the accent on the open tab; a progress bar or percent uses the same hue rule as the value it shows.
