# Security

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository (Security, Report a vulnerability).
Please do not open a public issue for a security problem. You will get an answer within 7 days.

## What RMJ is trusted with

RMJ runs as you on your Mac, with your permissions and no more: no root helper, no daemon, no
`sudo`. It reads your Tailscale status, connects over ssh to boxes you name, with your ssh keys and
known_hosts, syncs your checkouts there and runs the commands you or your agents start. It reads
your GitHub Actions runs with your logged-in `gh`. It can store GitHub personal access tokens you
paste in the macOS Keychain and write them into a runner stack's `.env` on a box you chose. It can
rerun a job, start or stop a runner container, and delete stale runner registrations, each on your
press.

## Threat model and trust boundaries

1. **Transport: tailnet only.** Every connection goes to the destination peer's current
   Tailscale address, taken from the peer list by the stored node ID at connect time and passed
   to ssh as `HostName`; the ssh alias supplies only the user and the host-key name, and
   `ProxyCommand`, `ProxyJump` and connection multiplexing are disabled on the command line so
   nothing in `~/.ssh/config` can redirect the connection. rsync uses the same ssh argv.
   `BatchMode`, `StrictHostKeyChecking=yes`; a changed host key is an error, never accepted.
   There is no public-IP or HTTP fallback (a Tailscale relayed connection is still the tailnet).
2. **No shell strings from untrusted text.** Commands cross to the box as a JSON argv array and
   run with `exec`, no shell, unless the owner or the guard asked for `--shell` explicitly; paths,
   repo names and log text are argv or data everywhere. Tested with literal metacharacters in
   both modes.
3. **Tenant separation.** A `globex` job never reaches a `acme` destination and the reverse. The
   deny sits before the rules and no rule overrides it. Tested, with the explain line.
4. **Secrets.** On the Mac, PATs live in the Keychain only (`rmj.pat.<target>`), never in
   `config.json`, `rules.json`, the ledger, a log, a notification or a tool result; their values
   are redacted from every stream before it is written locally. On a box, the runner stack needs
   the PAT in `<stack>/.env` (mode 600, written atomically without following symlinks): that is
   a documented second copy, listed in Settings per destination, rewritten on rotation for every
   reachable box (unreachable ones shown as pending) and removed when the destination is removed
   and reachable. RMJ never stores a GitHub token of its own; `gh auth token` is used per call.
5. **Logs and GitHub text are untrusted.** Terminal escapes and invisible Unicode are stripped
   before display or return to an agent; nothing in a log, a workflow name or a runner name is
   interpreted or executed.
6. **Agent access over MCP is read-only and off by default.** `rmj mcp` can read the ledger,
   destinations, route explanations and redacted archived logs; it cannot run, rerun, cancel,
   prune or deploy, and it never opens ssh. An unreadable config counts as off. The switch covers
   MCP only: the CLI has acting verbs (`run`, `rerun`, `cancel`, `runners --prune`, `hooks`,
   `prune`) that a harness must withhold from an agent meant to inspect only.
7. **Fail closed to local.** An invalid rules file, a tailnet that is not running, a peer that is
   offline or an address that is not a tailnet address all route the job to the Mac, with the
   reason recorded. Nothing is retried on a different transport.
8. **What runs on a box runs as the box's ssh user,** in a container with the limits from the
   rules, on the box's Docker. RMJ does not escalate there and installs nothing; the runner stack
   it deploys is the vendored compose stack whose security model is in
   `Support/runner-stack/README.md` (ephemeral runners, no PAT in a job's environment, no Docker
   socket, no inbound port).
9. **Network.** Destinations: ssh and rsync to verified tailnet addresses, `api.github.com` via
   `gh`, the update check against this repository's releases, and the More apps list: one file and its
   icons from `raw.githubusercontent.com/danieltamas/registry`, validated before use (ASCII, at most 64 KiB,
   hosts and install commands on an allowlist, icons PNG 256 x 256 at most 64 KiB) and stored under
   `~/.rmj/registry/`. Nothing else, no telemetry.

## Data kept on this Mac

`~/.rmj` (mode 0700): `config.json`, `rules.json`, `rmj.sqlite` (30 days of jobs, events, probe
samples, registrations seen), `logs/` (30 days of run logs, PAT values redacted, otherwise as
printed, 2 GB cap). Removing the folder removes everything except the Keychain items, which
Settings > Destinations deletes per target, and the `.env` copies on the boxes, which Remove
destination handles.
