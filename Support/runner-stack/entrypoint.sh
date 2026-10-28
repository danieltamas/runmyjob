#!/usr/bin/env bash
# Register this container as one ephemeral GitHub Actions runner, then run exactly one job.
#
# Credential boundary: a job step inherits the runner's environment and sees its filesystem, and a
# PR branch is untrusted code. So the PAT is read once here, exchanged for a one-hour registration
# token, and both are unset before the runner process starts. After `exec` the process environment
# (and /proc/1/environ) no longer holds them. The runner itself holds only its own per-registration
# credential, which GitHub revokes when the ephemeral job ends.
#
# Environment (set in docker-compose.yml):
#   RUNNER_SCOPE        org | repo
#   RUNNER_TARGET       <org>  |  owner/repo
#   RUNNER_LABELS_BASE  labels every runner on this host carries
#   RUNNER_LABELS       the label that routes a workflow to this runner alone
#   GH_PAT              fine-grained token that may create registration tokens for RUNNER_TARGET
#   RUNNER_REG_TOKEN    a ready registration token (one-shot smoke test only; no re-registration)
#   FORWARDS            space-separated "localport:host:port" loopback forwards to the siblings,
#                       e.g. "5432:pg:5432 6379:redis:6379" (for suites that expect a service on loopback)
set -euo pipefail

: "${RUNNER_SCOPE:?org or repo}" "${RUNNER_TARGET:?org or owner/repo}" "${RUNNER_LABELS_BASE:?}"
labels="${RUNNER_LABELS_BASE}${RUNNER_LABELS:+,$RUNNER_LABELS}"

if [ -z "${GH_PAT:-}" ] && [ -z "${RUNNER_REG_TOKEN:-}" ]; then
  echo "entrypoint: no GH_PAT and no RUNNER_REG_TOKEN for ${RUNNER_TARGET}; idle for an hour instead of restart-looping" >&2
  sleep 3600
  exit 1
fi

case "$RUNNER_SCOPE" in
  org)  api="https://api.github.com/orgs/${RUNNER_TARGET}/actions/runners/registration-token" ;;
  repo) api="https://api.github.com/repos/${RUNNER_TARGET}/actions/runners/registration-token" ;;
  *) echo "entrypoint: RUNNER_SCOPE must be org or repo, got '${RUNNER_SCOPE}'" >&2; exit 64 ;;
esac
url="https://github.com/${RUNNER_TARGET}"

if [ -n "${RUNNER_REG_TOKEN:-}" ]; then
  token="$RUNNER_REG_TOKEN"
else
  token="$(curl -fsS -X POST "$api" \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" | jq -r '.token // empty')" || token=""

  # Stale registrations: an ephemeral runner that dies before its job (container recreated, box
  # frozen) stays registered offline, and GitHub keeps assigning queued jobs to such a runner
  # (a job can queue for minutes behind one). Sweep the target's offline, idle
  # runners every start, while the PAT is still here. Only this stack's own registrations
  # (<12 hex container id>-<epoch>, labelled with this box) older than 10 min: never another
  # machine's runner, never one that is merely reconnecting; busy ones are GitHub's to reap.
  runners_api="${api%/registration-token}"
  box_label="${RUNNER_LABELS_BASE##*,}"
  cutoff=$(( $(date +%s) - 600 ))
  for page in 1 2 3; do
    stale="$(curl -fsS "${runners_api}?per_page=100&page=${page}" \
      -H "Authorization: Bearer ${GH_PAT}" -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      | jq -r --arg box "$box_label" --argjson cutoff "$cutoff" '
          .runners[] | select(.status=="offline" and .busy==false)
          | select(.name | test("^[0-9a-f]{12}-[0-9]{10}$"))
          | select((.name | split("-")[1] | tonumber) < $cutoff)
          | select([.labels[].name] | index($box) != null)
          | "\(.id) \(.name)"')" || break
    [ -n "$stale" ] || break
    while read -r id rname; do
      if curl -fsS -o /dev/null -X DELETE "${runners_api}/${id}" \
           -H "Authorization: Bearer ${GH_PAT}" -H "Accept: application/vnd.github+json" \
           -H "X-GitHub-Api-Version: 2022-11-28"; then
        echo "entrypoint: removed stale offline runner ${rname} (${id}) from ${RUNNER_TARGET}"
      else
        echo "entrypoint: could not remove stale runner ${rname} (${id}); continuing" >&2
      fi
    done <<< "$stale"
  done
fi
unset GH_PAT RUNNER_REG_TOKEN
if [ -z "$token" ]; then
  echo "entrypoint: GitHub did not issue a registration token for ${RUNNER_TARGET} (token scope or target wrong); retry in 5 min" >&2
  sleep 300
  exit 1
fi

# The container filesystem survives a restart; --ephemeral only deregisters. A fresh job gets a
# fresh workspace and a fresh registration, never the previous job's files or credential.
rm -rf /home/runner/_work /home/runner/.runner /home/runner/.credentials /home/runner/.credentials_rsaparams \
       /home/runner/_diag/pages
mkdir -p /home/runner/_work /home/runner/_diag/pages

# Live job output in `docker logs` (Dozzle): the runner's own stdout carries only its trace; each
# step's output goes to a page file under _diag/pages (and to GitHub). Tail every page as it
# appears, without the per-line timestamp the runner adds. One job per container, so the loop ends
# with the container; tini reaps the tails like the socat forwards.
(
  cd /home/runner/_diag
  seen=" "
  while :; do
    for f in pages/*.log; do
      [ -e "$f" ] || continue
      case "$seen" in *" $f "*) continue ;; esac
      seen="$seen$f "
      tail -n +1 -F "$f" 2>/dev/null | sed -u 's/^[0-9]\{4\}-[0-9T:.]*Z //' &
    done
    sleep 2
  done
) &

# The suites accept only the loopback, on the developer's Docker test ports (scratch-db.ts,
# assertDockerTestDb: 127.0.0.1:55439; the Redis suites: 127.0.0.1:56399), so the siblings are
# reached through those same addresses inside this container.
for fwd in ${FORWARDS:-}; do
  local_port="${fwd%%:*}"
  target="${fwd#*:}"
  socat "TCP-LISTEN:${local_port},bind=127.0.0.1,fork,reuseaddr" "TCP:${target}" &
done

name="${HOSTNAME}-$(date +%s)"
if ! ./config.sh --unattended --ephemeral --replace --disableupdate \
     --url "$url" --token "$token" --name "$name" --labels "$labels" --work _work; then
  echo "entrypoint: registration of ${name} for ${RUNNER_TARGET} failed (token expired or revoked?); retry in 5 min" >&2
  sleep 300
  exit 1
fi
unset token
echo "entrypoint: registered ${name} for ${RUNNER_TARGET} with labels ${labels}; waiting for one job"
# tini becomes PID 1 here, with this clean environment, and reaps the socat children.
exec /usr/bin/tini -- ./run.sh
