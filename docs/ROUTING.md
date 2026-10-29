# Routing: destinations, tenants, rules, jobs, reachability, the rx contract, logs

This file is the data contract. The app edits `~/.rmj/rules.json`; `rmj run`, the guard and the
panel read it. A build still routes correctly when the app is not running, because the file is the
truth and the app is its editor. It covers rx jobs (commands RMJ routes); GitHub jobs are routed
by their workflow's `runs-on` labels and RMJ only maps labels to the destinations that host the
runners (PLAN.md U5).

## Destinations

A destination is a Linux box on the owner's tailnet with ssh, docker and rsync. Nothing of RMJ is
installed there. State a run leaves on a box is files under `<home>/rx/` written by the run.

The file is strict JSON (no comments; D8). The shipped default:

```json
{
  "destinations": {
    "ai-eu-1": {
      "enabled": true,
      "peer_id": "nABC123CNTRL",
      "ssh_alias": "ai-eu-1",
      "tenant": "acme",
      "roles": ["rx", "runners"],
      "home": "/home/ubuntu",
      "max_jobs": 3,
      "memory_budget": "36g",
      "rx_defaults": { "cpus": 8, "memory": "12g" },
      "runner_stack": "/home/ubuntu/infra/gh-runners",
      "runner_targets": ["acme/ledger", "acme/atlas", "org:Acme"]
    },
    "s1": {
      "enabled": false,
      "peer_id": "",
      "ssh_alias": "s1",
      "tenant": "globex",
      "roles": ["rx", "runners"],
      "home": "/home/globex",
      "max_jobs": 2,
      "memory_budget": "24g",
      "runner_targets": ["org:globex"]
    }
  }
}
```

| Key | Meaning |
|-----|---------|
| `enabled` | A disabled destination is validated loosely (an empty `peer_id` is allowed), never probed and never chosen; `s1` ships disabled until U13 fills it in |
| `peer_id` | The Tailscale node ID stored when the destination was added; names may change, the ID does not |
| `ssh_alias` | Supplies the user and the host-key name only; the address comes from the peer list |
| `max_jobs` | rx containers at once |
| `memory_budget` | rx limits plus what the runners use now must stay under it (a 52 GB box that also runs ollama on the GPU). Runner caps are not summed: on `ai-eu-1` they add up to 32 g, which would leave no room under a 36 g budget |
| `rx_defaults` | Container limits for rules that set none |
| `runner_stack`, `runner_targets` | Where the vendored compose stack lives and which repos or orgs its runners register for |
| `requires` | Programs and shells the box must provide, e.g. `["bash", "zsh", "bun"]`. Setup checks each with `command -v` after docker and rsync and fails with `missing on the box: zsh` and an install hint; names are letters, digits and `._+-`, no duplicates |

Known today: `ai-eu-1` is a WSL2 VM (24 CPUs, 52 GB) that also runs ollama on the GPU; it
froze once (2026-10-27, 14:43-14:49) under a cold Rust build while an rx DuckDB build had run an
hour before, so the memory budget exists and the heartbeat marks a job `lost` when the box stops
answering. s1 is the Globex box; Globex repos build there and nowhere else.

## Tenants and repository identity

A repo's identity is the canonical `owner/name` from its origin URL (ssh or https, with or without
`.git`, lower-cased), plus the worktree path and a `dirty` flag. Tenant resolution, first match:
the `repos` table, then the `owners` table, else `unclassified`. An unclassified repo routes
locally with that reason until the owner classifies it; nothing is `personal` by default.

```json
{
  "tenants": {
    "acme": { "owners": ["acme"], "repos": ["acme/ledger", "acme/atlas"] },
    "globex":      { "owners": ["globex"], "repos": ["globex/portal*", "globex/gateway*"] },
    "personal": { "shared": true, "repos": ["acme/notes", "acme/dotfiles"] }
  }
}
```

There is no shipped table: a fresh install has no tenants, and every tenant, owner and repo is the user's own
configuration in `~/.rmj/rules.json`. A repo that no tenant claims is `unclassified` on purpose.

The deny sits before the rules and nothing overrides it, not a rule, not `--to`: a `globex` job never
runs on a `acme` destination and the reverse; a tenant marked `"shared": true` (one person's own repos) is not a company: its jobs may run on any destination a
rule names, and its destinations take any repo. The explain says `denied: tenant globex on acme destination` and continues down the chain.

## Rules

Ordered; first match wins; `local` is always the last link of every chain, written or not.

```json
{
  "rules": [
    { "name": "cargo build stays local (the box builds x86_64)",
      "match": { "command": ["cargo build"] },
      "to": ["local"],
      "advisory": "the box builds x86_64 Linux binaries; a binary for this Mac is built here" },
    { "name": "cargo repos to the rust image",
      "match": { "tenant": ["acme", "personal"], "command": ["cargo", "just"], "has": "Cargo.toml" },
      "to": ["ai-eu-1"],
      "image": "rx-rust",
      "volumes": ["rx-cargo-registry:/usr/local/cargo/registry", "rx-cargo-git:/usr/local/cargo/git",
                  "rx-rustup:/usr/local/rustup", "rx-target-{repo}:/work/target"],
      "cold_marker": { "acme/atlas": "Compiling libduckdb-sys" } },
    { "name": "ledger gate image with its dev pair",
      "match": { "repo": ["acme/ledger"] },
      "to": ["ai-eu-1"],
      "profile": "ledger" },
    { "name": "Globex repos to s1",
      "match": { "tenant": ["globex"] },
      "to": ["s1"],
      "image": "rx-node" }
  ]
}
```

`match` keys: `owner`, `repo` (globs on `owner/name`), `tenant`, `path` (glob on the worktree
path), `command` (the first word, or the first word and subcommand for `cargo` and `just`), `has`
(a file that must exist in the checkout). All given keys must match. `to` is a chain tried in
order; a destination is skipped when it is offline, unreachable, denied by tenant, at `max_jobs`,
or over its memory budget. A `profile` names `Support/box/profiles/<name>.json` holding the
complete run environment a repo needs (image, network, user, mounts, environment, prelude script,
lock name). `cold_marker` maps a repo to the log line that means a cold build there (History shows
warmth only for repos that have one). ledger's profile is transcribed from `~/agent-os/adapters/rx` and `rx.d/ledger.sh` as they
are (`gh-runner:2.338.2`, network `gh-runners_ci`, user 1000, `HOME=/tmp`, the bun cache volume,
forwards to `dev-pg-ledger` and `dev-redis-ledger`, lock `ledger`) and tested against the
developer pair before the port is called unchanged.

Validation: unknown keys, a `to` naming an unknown destination, an unknown profile,
duplicate names, a `memory` above the destination's budget are errors. An image is checked at routing time against the probe's image list (a destination without it is skipped: `<dest> lacks image <name>`), since the Mac cannot know the images of a box when the file is read. On any error every job
routes locally with `rules invalid: <path> <message>` and the panel shows it; the app never
overwrites the last valid file with an invalid one.

Reasons a job runs locally, each recorded as the row's `fallback_reason` and shown in the panel:
`tailnet down`, `<dest> offline (peer offline)`, `<dest> unreachable (ssh timeout)`, `denied:
tenant ...`, `<dest> at max_jobs`, `<dest> over memory budget`, `unclassified repo`, `no rule`,
`rules invalid: ...`, `sync failed`, `container start failed`, `forced` (`RX_LOCAL=1`). A red
suite is never a reason; its exit code is returned as is.

## Reachability over Tailscale

RMJ depends on Tailscale and says so. At every connect, in order:

1. `tailscale status --json`: `BackendState == "Running"` and `Self.Online`. Anything else is
   `tailnet down` (with the backend state), every destination is offline, no ssh is attempted.
2. The destination's peer is found by its stored node `ID`; `Online` must be true (`LastSeen`
   shown otherwise). The address is the peer's current `TailscaleIPs[0]` (`100.64.0.0/10` or
   `fd7a:115c:a1e0::/48`); nothing is resolved through DNS, so MagicDNS off, split DNS and
   renames change nothing. A relayed connection is still the tailnet (shown as `relayed`); an
   expiring key is shown with its date.
3. ssh is invoked with argv, and the alias supplies only the user and the host-key name:
   `ssh -o HostName=<verified ip> -o HostKeyAlias=<alias> -o ProxyCommand=none -o ProxyJump=none
   -o ControlMaster=auto -o ControlPath=~/.rmj/ssh/%C -o ControlPersist=10m -o BatchMode=yes -o ConnectTimeout=5 -o RequestTTY=no
   -o StrictHostKeyChecking=yes -o ServerAliveInterval=15 <alias> -- <argv>`; rsync's `-e` carries
   the same. A changed host key is an error shown in the panel, never accepted. There is no
   public-IP fallback and no other transport.
4. The probe: `docker info`, `rsync --version`, `docker image ls`, `nproc`, `free -m`,
   `/proc/loadavg`, `docker ps` with the `rx` and runner labels plus one `docker stats` sample,
   `/proc/sys/kernel/random/boot_id`, `date +%s%N`.

Cadence: tailnet state every 10 s while the panel is open or a job runs, every 60 s otherwise, and
on wake; probes every 30 s per destination while a job runs there, every 5 min otherwise, on
demand, and at most 60 s old when a run is dispatched (older: one probe first). The cache lives
in the ledger (`destination_sample`) so `rmj run` uses it with the app closed.

## The job model

```
job
  id               ULID, allocated before dispatch, used in every remote name and record
  source           rx | github
  tenant           acme | globex | personal | unclassified
  repo             owner/name (canonical)
  worktree         local path (rx) or null
  branch, commit, dirty
  command          the argv (rx; with `shell: true` when run through --shell) or "<workflow> / <job>"
  agent            claude-code | codex | opencode | hermes | terminal | github, plus session id
  location         destination name | local | github-hosted
  fallback_reason  null, or one of the reasons above (location local)
  environment      box | mac (mac means a suite may have skipped Linux-only cases)
  rule             the rule's name, or null
  state            queued | syncing | running | done | failed | cancelled | lost | skipped
  exit             the command's exit code (rx, local) or null
  github           run_id, job_id, run_attempt, status, conclusion, html_url, runner_name, labels,
                   current_step, steps_done, steps_total, observation (see U5), parent_attempt
  times            queued_at, sync_started_at, sync_ended_at, started_at, ended_at (mac clock, UTC ms)
                   box_started_at, box_ended_at, box_exit (from <name>.meta)
                   github created_at, started_at, completed_at (as given)
                   mac_elapsed_ms (monotonic, when the Mac attended the whole run)
                   clock_offset_ms (box minus Mac, from the probe)
  warmth           warm | cold | unknown (from the rule's cold_marker only)
  logs             box path; local path; status available | pending | unavailable(reason); truncated
job_event (job_id, at, state, detail)
```

Duration shown: the box pair when both exist and end is after start; else `mac_elapsed_ms`; else
`unknown`. The provenance is shown next to it (`timing: box`, `timing: mac`). Sync time is the
Mac's cost, shown apart. Lifecycle (`state`) and location are separate: a local fallback that
fails is `failed` at `local` with its reason, and appears in failures and notifications like any
other.

## The rx contract (what runs on the box)

Ported from `~/agent-os/adapters/rx` and `rx.d/rx-run.sh`, with the additions the review asked
for; `Support/box/rx-run.sh` is the box side and is shipped before every run when its checksum
differs.

- Names: container `rx-<repo>-<ulid suffix>`, label `rmj.job=<ulid>`, records
  `<home>/rx/.logs/<ulid>.{argv,launch,log,rc,meta}`. Sync dir `<home>/rx/<repo>/<worktree hash>/`
  with a `.rmj-worktree` file naming the Mac path, so two clones with the same directory name
  never share a dir.
- Locks: `flock <dir>.lock` is taken by `rx-run.sh` before the sync and handed to the waiter, which
  holds it until the container ends; a profile's `lock` is a second flock held the same way. The
  lock outlives the ssh client because the waiter does.
- Sync: `rsync -az --delete` of the files git sees (tracked, including gitignore-hidden tracked
  files, plus untracked edits; never ignored output, never `.git`, never a symlink out of the
  checkout) into the locked dir.
- Launch: `rx-run.sh <ulid> <docker run args...>` writes `<ulid>.launch` = `started <container id>
  <boot_id>` after `docker run -d` succeeds, or `start-failed <docker's message>` and exits 125.
  The client treats only `start-failed` (or no launch record plus a probe proving no container with
  the label) as grounds for a local fallback; 125 from a started command is the command's.
- Argv: the command is `<ulid>.argv` (a JSON array) and the container runs it with
  `--entrypoint /work/.rmj/exec` (a 3-line script: `exec "$@"`) and the array as arguments; a
  `shell: true` run passes `bash -c <string>` as that array. No shell interprets argv mode.
- Streaming: the waiter starts `docker logs -f > <ulid>.log` at once; the client streams the same
  and writes the local copy. On end the waiter writes `.rc`, `.meta` (`started= finished= exit=`
  from `docker inspect`), removes the container, releases the locks, and prunes records older
  than 30 days (by file time, which is completion time for these files). `.rc` is written last,
  so its presence means the others are complete.
- Cancel: `docker rm -f` by label over ssh; the waiter sees the exit and records `cancelled` in
  `.rc` (`exit=137 cancelled`).
- Reconcile: for a job in `running` or `lost`, read `.launch`, `.rc`, `.meta`, the container's
  presence and the current `boot_id`. Container gone, no `.rc`, boot changed: `lost: destination
  rebooted`, partial log pulled. `.rc` present: settle with box timing. Container present:
  still running, keep streaming from the log file.
- Images are built on the box from `Support/box/images/<name>/Dockerfile` (`rx-rust` today;
  `rx-node` when bun and node are routed).

## Logs and retention

- Box: `<home>/rx/.logs/` keeps every run's `.log`, `.rc`, `.meta` 30 days after completion;
  pruned by the waiter at every run end, by the app's daily pass and by `rmj prune` for every
  reachable destination. Nothing prunes unattended; an idle box keeps its last 30 days until the
  Mac next touches it (a non-goal to change: no timers on boxes).
- Mac: `~/.rmj/logs/<ulid>.log` for every completed run (rx pulled, local written directly,
  GitHub fetched for failed jobs at once and others on demand). Pulls that cannot happen are
  `pending` and retried at every reconcile. Caps: 50 MB per log with a truncation marker, 2 GB
  total; a full disk keeps the row and marks the log unavailable.
- Redaction before persistence: the Keychain PAT values are replaced across chunk boundaries
  before any local write; display and agent access additionally strip terminal escapes and
  invisible Unicode. The box-side file is what the command printed.
- Retention: 30 days from completion for rows and files; `queued`, `syncing`, `running`, `lost`
  rows and rows with a `pending` log are never expired; files first, row last.

## Hooks (how an agent's command reaches the router)

Claude Code: `PreToolUse` on Bash calls `rmj guard` with the command and cwd; in a classified repo
the guard blocks `cargo test|check|clippy|nextest|bench|doc|deny`, `cargo fmt --check`, `just
check|test|lint|deny` and `scripts/check.sh` at command position and prints the `rmj run --
<command>` form (`--shell` when the command carries shell syntax), whether the router's answer is
remote or local, so local fallbacks are recorded. `cargo build` gets one advisory line. `RX_LOCAL=1`,
commands already under `rmj run`, and commands in an unclassified repo (with an advisory naming the
repo) pass. Quoted strings and heredoc bodies are blanked before matching; newlines, `;`, `&&`,
`||`, `$(`, `(` and a leading `VAR=value` or `cd dir &&` are handled as in the contextual cases of
PLAN.md U9. The reference and its 38 cases: `~/agent-os/hooks/shared/remote-build-guard.sh`,
`hooks/shared/tests/`. The guard is routing assistance; the tenant deny lives in the router.

Other harnesses: the same guard through their pre-command hook where one exists; shims for
`cargo` and `just` where none does (PLAN.md D2); `scripts/check.sh` is not coverable there and the
Settings row says so. "No destination" is never an error for the agent: the command runs where it
would have run, and the ledger says `local` with the reason.
