# runner stack: GitHub Actions runners on a destination

RMJ deploys this directory to `<home>/infra/gh-runners` on a destination whose roles include `runners`
(Settings > Destinations, or `rmj ops deploy <destination>`). It adds one ephemeral runner container per
entry of the destination's `runner_targets` (`owner/repo` or `org:<name>`), hands it the Keychain tokens
over ssh (never written to a file on the box), and checks that every runner registered with GitHub. Nothing here is specific to a repo or company.

## How a job reaches a runner

GitHub is the queue. Each runner container registers with its target (an org, or one repo) and long-polls
GitHub over outbound HTTPS; nothing is exposed inbound. A workflow selects a runner with
`runs-on: [self-hosted, linux, <label>]`, where `<label>` is the runner's own label (the repo or org name).

A personal GitHub account has no org, so each private repo of a personal account gets its own runner (one
service, idle at about 100 MB; limits are caps, not reservations). Public repos should stay on GitHub-hosted
runners: any fork can open a PR that a self-hosted runner would execute.

## Security model

- A runner executes whatever the PR branch contains. It runs unprivileged, with `no-new-privileges`, a pid
  limit, no Docker socket, no published port, on a private network.
- The token never reaches a job. `entrypoint.sh` exchanges it for a one-hour registration token, unsets both
  and only then `exec`s tini and the runner, so PID 1 and every job step inherit a clean environment.
- Ephemeral: one job per registration. The container exits, `restart: unless-stopped` starts it again and the
  entrypoint wipes `_work` and the old registration before registering anew. A runner that dies before its job
  stays registered offline; every start deletes this stack's own stale registrations (offline, idle, older
  than ten minutes) before registering.
- Use `pull_request` only (never `pull_request_target`), exclude fork PRs, and keep production secrets out of
  these workflows. The only credentials on the box are the tokens in the runner containers' environment (the entrypoint unsets them before a job runs); there is no `.env`.

## Limits

Every generated runner gets 4 CPUs, 8 GB and a pid limit as caps. `docker-compose.rmj.yml` is generated and
overwritten by every deploy, as is the rest of this directory on the box, so do not hand-edit them there.

## Operate

    cd <home>/infra/gh-runners
    docker compose logs -f runner-<name>      # "registered ... waiting for one job"
    docker compose restart runner-<name>      # drops the current registration and registers again
    docker compose stop runner-<name>         # take one runner offline

## rx: agents' own runs

`rmj run` starts a container per command on the same box, with caches on named volumes, separate from the
runners. See docs/ROUTING.md.
