# RMJ (Run My Job): instructions for agents

RMJ is an open source (MIT) macOS menu bar app plus a CLI (`rmj`) that routes builds, test suites
and CI jobs from this Mac to the owner's fleet boxes over Tailscale and tracks every run in one
place: destinations, routing rules, running and queued jobs, history with exact timings, logs for
30 days, rerun. Nothing is installed on the boxes; they need ssh, docker and rsync. Owner: Daniel
Tamas. Repo: github.com/danieltamas/runmyjob (to be created by the owner; see docs/PLAN.md).

## Start here

1. Read `docs/PLAN.md`: what it is, complete-when, measured-by, the unit layout (U0..U13),
   acceptance and quality criteria per unit, open decisions.
2. Read `docs/ROUTING.md` (the rules file, the job model, the contract with `rx`) and
   `docs/ARCHITECTURE.md` (targets, data flow, pollers, store).
3. Read MacMax's `docs/LESSONS.md` (`~/Sites/macmax/docs/LESSONS.md`, github.com/danieltamas/macmax):
   what Bton and MacMax taught about menu bar apps on this machine. Those are rules here too. RMJ
   copies its skeleton, theme, components, Settings parts, installer and release ceremony from
   MacMax's current `main`, not from Bton.
4. Read the companion doc for your unit (`docs/DESIGN.md`, `docs/AGENT-API.md`, `SECURITY.md`,
   `docs/reviews/`).
5. Take the first unit whose dependencies are done in PLAN.md's layout table. Nothing is built yet:
   start at U0. Each unit ends in a `/goal` line; run the unit under it.
6. The predecessor this app absorbs lives in `~/agent-os`: `adapters/rx` (the remote runner),
   `adapters/rx.d/rx-run.sh` (the box-side waiter), `hooks/shared/remote-build-guard.sh` (the
   pre-command guard, 38 test cases), `jobs/fleet-runners/` (the GitHub runner stack and its
   README), `rules/remote-build.md`. Read them before U3, U4, U6 and U9. They are the working
   reference implementation; RMJ ports them, it does not reinvent them.

## Stack

SwiftPM only (no Xcode project), Swift 6 language mode with strict concurrency, macOS 14 minimum
(the fleet is reached from one Mac; MacMax's macOS 13 gating is not needed), no third-party
packages. Targets: `RMJCore` (no SwiftUI or AppKit imports), `RMJ` (the app), `RMJCLI` (installed
as `rmj`; never a target named `rmj`, it collides with `RMJ` on a case-insensitive disk),
`RMJCoreTests` (Swift Testing). Bundle id `ro.danieltamas.rmj`. App home `~/.rmj` (or
`$RMJ_HOME`), mode 0700: `config.json`, `rules.json`, `rmj.sqlite`, `logs/`, `shims/` (never
secrets; those are in the Keychain).

## Build and test

Always an explicit scratch path outside the repo. In Claude Code, `swift`, `gh`, `codesign`,
`ssh`, `tailscale` and `codex` need the Bash sandbox off; `open` and `osascript` are blocked: hand
the owner the command. Swift builds stay on the Mac (the box is Linux); the pre-bash hook does not
divert `swift`.

```
SCRATCH=$HOME/.cache/rmj-build
swift build --build-tests --scratch-path "$SCRATCH"
swift test --skip-build --scratch-path "$SCRATCH" [--filter Topic]
RMJ_LIVE=1 swift test --skip-build --scratch-path "$SCRATCH" --filter Live   # real tailnet, real box
scripts/check.sh                 # build, tests, 500-line limit, ASCII punctuation lint
scripts/install-from-source.sh   # bundle and install to /Applications, CLI to ~/.local/bin
```

Live tests need the tailnet up and `ai-eu-1` reachable; they never touch a Globex box until
the owner says Globex starts (PLAN.md, U13).

## How a unit gets done

1. **Acceptance tests by Codex, not by you.** Give Codex the unit's Acceptance lines from PLAN.md
   and the relevant doc; it writes `Tests/RMJCoreTests/<Topic>AcceptanceTests.swift`. Hash the
   files and re-check the hash before every commit. You never edit those tests; a red test is
   fixed in `Sources/`. A test you believe is wrong goes back to Codex with the evidence.
   ```
   codex exec --sandbox workspace-write --skip-git-repo-check -C . --add-dir "$SCRATCH" \
     -o "$SCRATCH/codex-tests.md" - < "$SCRATCH/tests-prompt.md"
   ```
   Always give `codex exec` its stdin (`- < file` or `< /dev/null`), or it waits forever. Write
   prompt files with the Write tool, not heredocs.
2. **Implement** in `Sources/`, files under 500 lines, the file's idiom, no dead code.
3. **Review by Codex** of the unit's final diff (`--sandbox read-only`), every finding on its own
   line with a severity `P0`..`P3`; fix P0-P2, re-review the final diff, commit. Save the review
   under `docs/reviews/<unit>-<date>.md`.
4. **Verify** with the unit's `/goal` line and record the evidence in `LOG.md` (date, unit,
   commands, results, what is still open).

## Rules that are not negotiable

- **Tailscale only.** A destination is reached at its tailnet address, verified at every connect
  (`docs/ROUTING.md`, "Reachability"). No public IP, no fallback transport. Tailnet down means
  every destination is offline and jobs run locally, recorded as such.
- **Local fallback always exists.** No destination, no tailnet, no docker, a failed sync: the
  command runs on the Mac and the ledger says why. A red suite is never a fallback.
- **Two companies never mix.** A rule's `tenant` is a hard deny: `globex` repos never reach a
  `acme` destination and the reverse. Tested, not documented.
- **Secrets live in the Keychain.** GitHub PATs for runner registration are read from the Keychain,
  written to a box's `.env` over ssh (mode 600), never into the ledger, a log, a notification or
  `config.json`.
- **Logs are untrusted text.** Terminal escapes and invisible Unicode are stripped before display
  or return to an agent; nothing in a log is interpreted.
- **Plain ASCII punctuation** in README, docs, user-facing strings and commits (`-`, `"`, `'`,
  `...`). `scripts/check.sh` fails on en and em dashes, curly quotes, the ellipsis character, NBSP.
- Conventional Commits, no co-author trailers, commit and push only when the owner asks.
