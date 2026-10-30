#!/usr/bin/env bash
# rx-run (runs on the box): the box side of `rmj run`. Nothing of RMJ is installed here besides this
# script, shipped before a run when its checksum differs. Records live under ~/rx/.logs for 30 days:
#   <ulid>.argv  the command as a JSON array      <ulid>.launch  "started <container> <boot_id>" or "start-failed <why>"
#   <ulid>.log   the container's output           <ulid>.rc      the exit code (last word "cancelled" after a cancel); written last
#   <ulid>.meta  started= finished= exit=         <ulid>.wait    the job holding the lock this one waits for
#
#   begin  <ulid> <worktree> <dir> [lockfile...]   start the detached waiter; returns when it holds the locks
#   go     <ulid> <name> <argv-json> -- <docker run args...>   start the container; prints the launch record
#   tail   <ulid>                                  stream the log until the run ends; exit with its code
#   log    <ulid>                                  print the whole log so far
#   stats  <ulid>                                  the container's cpu and memory now: `<cpu%> <used> / <limit>` per container
#   cancel <ulid>                                  remove the container by label; stop a waiter that has not started
#   job    <ulid>                                  print "container <present|absent> <boot_id>" and the records that exist
#   secret <ulid> <name>                           write stdin to <name> in a private tmpfs directory for the job; prints the directory
#   unsecret <ulid>                                remove that directory
#   prune                                          drop records older than 30 days
set -u
logs=$HOME/rx/.logs
mkdir -p "$logs"
boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)

# A pid file outlives its process: it counts only while that pid still is this job's waiter.
waiter_alive() {
  local pid; pid=$(cat "$logs/$1.pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "_waiter $1 "
}

valid_ulid() { [[ $1 =~ ^[0-9A-Za-z]{10,40}$ ]] || { echo "rx-run: bad job id" >&2; exit 2; }; }

waiter() {
  local ulid=$1 worktree=$2 dir=$3; shift 3
  local fd=20 lock
  echo $$ > "$logs/$ulid.pid"
  for lock in "$@"; do
    mkdir -p "$(dirname "$lock")"
    lock_failed() { printf 'start-failed lock %s\n' "$lock" > "$logs/$ulid.launch"; printf '125 start-failed\n' > "$logs/$ulid.rc"; exit 1; }
    eval "exec $fd>\"\$lock\"" 2>/dev/null || lock_failed
    if ! flock -n $fd; then
      printf '%s\n' "$(cat "$lock.holder" 2>/dev/null || echo unknown)" > "$logs/$ulid.wait"
      flock $fd || lock_failed
      rm -f "$logs/$ulid.wait"
    fi
    printf '%s\n' "$ulid" > "$lock.holder"
    fd=$((fd + 1))
  done
  mkdir -p "$dir/.rmj"
  printf '%s\n' "$worktree" > "$dir/.rmj-worktree"
  printf '%s\n' '#!/bin/sh' 'if [ -f /prelude.sh ]; then exec bash -c '"'"'. /prelude.sh; exec "$@"'"'"' _ "$@"; fi' 'exec "$@"' > "$dir/.rmj/exec"
  chmod 755 "$dir/.rmj/exec"
  : > "$logs/$ulid.locked"
  local waited=0
  while [ ! -e "$logs/$ulid.go" ] && [ ! -e "$logs/$ulid.abort" ] && [ $waited -lt 7200 ]; do sleep 0.5; waited=$((waited + 1)); done
  if [ -e "$logs/$ulid.abort" ] || [ ! -e "$logs/$ulid.go" ]; then
    [ -e "$logs/$ulid.cancelled" ] && printf '137 cancelled\n' > "$logs/$ulid.rc"
    rm -f "$logs/$ulid.locked" "$logs/$ulid.abort"; exit 0
  fi
  local -a args=()
  while IFS= read -r -d '' word; do args+=("$word"); done < "$logs/$ulid.spec"
  local name=${args[0]}; args=("${args[@]:1}")
  # `--user @box` is the box user: the synced tree is theirs and must stay writable. Only docker's own options are
  # looked at (they end at --entrypoint), never the job's command.
  local i
  for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[i]}" = --entrypoint ] && break
    if [ "${args[i]}" = --user ] && [ "${args[i+1]:-}" = @box ]; then args[i+1]="$(id -u):$(id -g)"; break; fi
  done
  if ! out=$(docker run -d --name "$name" --label rx --label "rmj.job=$ulid" "${args[@]}" 2>&1); then
    printf 'start-failed %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)" > "$logs/$ulid.launch"
    printf '125 start-failed\n' > "$logs/$ulid.rc"
    exit 0
  fi
  printf 'started %s %s\n' "$out" "$boot_id" > "$logs/$ulid.launch"
  # A cancel that arrived while docker was still creating the container found nothing to remove.
  [ -e "$logs/$ulid.abort" ] && docker rm -f "$name" > /dev/null 2>&1
  docker logs -f "$name" > "$logs/$ulid.log" 2>&1 &
  local follower=$!
  local rc; rc=$(docker wait "$name" 2>/dev/null) || rc=1
  wait $follower 2>/dev/null
  docker inspect --format 'started={{.State.StartedAt}} finished={{.State.FinishedAt}} exit={{.State.ExitCode}}' "$name" \
    > "$logs/$ulid.meta" 2>/dev/null || printf 'started=? finished=? exit=%s\n' "$rc" > "$logs/$ulid.meta"
  docker rm -f "$name" > /dev/null 2>&1
  if [ -e "$logs/$ulid.cancelled" ]; then printf '%s cancelled\n' "$rc" > "$logs/$ulid.rc"; else printf '%s\n' "$rc" > "$logs/$ulid.rc"; fi
  rm -f "$logs/$ulid.go" "$logs/$ulid.spec" "$logs/$ulid.locked"
  prune
}

# A job's credentials live on tmpfs only, in a directory the box user alone can enter.
secret_dir() { printf '%s/rmj-%s' "${XDG_RUNTIME_DIR:-/dev/shm}" "$1"; }

prune() {
  for ext in argv launch log rc meta wait cancelled abort pid; do find "$logs" -name "*.$ext" -mtime +30 -delete 2>/dev/null; done
  find /dev/shm "${XDG_RUNTIME_DIR:-/dev/shm}" -maxdepth 1 -name 'rmj-*' -mtime +1 -exec rm -rf {} + 2>/dev/null
}

case "${1:-}" in
  begin)
    shift; valid_ulid "$1"; ulid=$1; worktree=$2; dir=$3; shift 3
    rm -f "$logs/$ulid".{locked,go,abort,wait,launch,rc,meta,log,cancelled,spec,pid}
    setsid -f bash "$0" _waiter "$ulid" "$worktree" "$dir" "$@" > /dev/null 2>&1 < /dev/null
    announced=0
    for _ in $(seq 1 7200); do
      if [ -e "$logs/$ulid.locked" ]; then echo locked; exit 0; fi
      if [ -s "$logs/$ulid.rc" ]; then if [ -s "$logs/$ulid.launch" ]; then echo failed; exit 5; else echo cancelled; exit 4; fi; fi
      if [ -e "$logs/$ulid.wait" ] && [ $announced = 0 ]; then echo "waiting for $(cat "$logs/$ulid.wait")"; announced=1; fi
      sleep 0.5
    done
    echo "rx-run: timed out waiting for the lock" >&2; : > "$logs/$ulid.abort"; exit 3 ;;
  _waiter) shift; waiter "$@" ;;
  go)
    shift; valid_ulid "$1"; ulid=$1; name=$2; argv=$3; shift 3; [ "${1:-}" = -- ] && shift
    printf '%s' "$argv" > "$logs/$ulid.argv"
    { printf '%s\0' "$name"; printf '%s\0' "$@"; } > "$logs/$ulid.spec"
    : > "$logs/$ulid.go"
    for _ in $(seq 1 120); do
      if [ -s "$logs/$ulid.rc" ] && [ ! -s "$logs/$ulid.launch" ]; then echo cancelled; exit 125; fi
      if [ -s "$logs/$ulid.launch" ]; then cat "$logs/$ulid.launch"; case $(cut -d' ' -f1 "$logs/$ulid.launch") in started) exit 0 ;; *) exit 125 ;; esac; fi
      sleep 0.5
    done
    echo pending ; exit 125 ;;
  tail)
    shift; valid_ulid "$1"; ulid=$1
    touch "$logs/$ulid.log"
    # --pid ends tail after a last read once the waiter, which writes the rc last, has gone: no byte is dropped.
    if waiter_alive "$ulid"; then
      tail -n +1 -F -s 0.1 --pid="$(cat "$logs/$ulid.pid")" "$logs/$ulid.log" 2>/dev/null
    else
      cat "$logs/$ulid.log" 2>/dev/null
    fi
    while [ ! -s "$logs/$ulid.rc" ]; do sleep 0.3; done
    rc=$(cut -d' ' -f1 "$logs/$ulid.rc"); exit "${rc:-1}" ;;
  log)
    shift; valid_ulid "$1"; [ -f "$logs/$1.log" ] || exit 1; cat "$logs/$1.log" || exit 1; exit 0 ;;
  cancel)
    shift; valid_ulid "$1"; ulid=$1
    : > "$logs/$ulid.cancelled"; : > "$logs/$ulid.abort"
    # A waiter still queued on a lock is stopped; one past its locks sees the abort file itself.
    if [ ! -e "$logs/$ulid.locked" ] && waiter_alive "$ulid"; then
      kill "$(cat "$logs/$ulid.pid")" 2>/dev/null && printf '137 cancelled\n' > "$logs/$ulid.rc"
    fi
    docker ps -aq --filter "label=rmj.job=$ulid" | xargs -r docker rm -f > /dev/null 2>&1
    rm -rf "$(secret_dir "$ulid")"
    exit 0 ;;
  job)
    shift; valid_ulid "$1"; ulid=$1
    # A docker that cannot answer is not an absent container: the Mac must not read it as one.
    ids=$(docker ps -aq --filter "label=rmj.job=$ulid" 2>/dev/null) || { echo "docker-error"; exit 1; }
    if [ -n "$ids" ]; then present=present; else present=absent; fi
    echo "container $present $boot_id"
    if waiter_alive "$ulid"; then echo "waiter alive"; else echo "waiter gone"; fi
    echo "now $(date +%s%3N)"
    for ext in launch rc meta; do [ -s "$logs/$ulid.$ext" ] && echo "$ext $(head -n1 "$logs/$ulid.$ext")"; done
    exit 0 ;;
  stats)
    shift; valid_ulid "$1"; ulid=$1
    ids=$(docker ps -q --filter "label=rmj.job=$ulid" 2>/dev/null) || exit 1
    [ -n "$ids" ] || exit 0
    docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' $ids; exit $? ;;
  secret)
    shift; valid_ulid "$1"; ulid=$1; name=${2:-}
    [[ $name =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "rx-run: bad secret name" >&2; exit 2; }
    dir=$(secret_dir "$ulid")
    # Memory-backed, and a directory this call created: never one that was there already or a link to somewhere else.
    case $(stat -f -c %T "$(dirname "$dir")" 2>/dev/null) in tmpfs|ramfs) ;; *) echo "rx-run: the secret directory is not on tmpfs" >&2; exit 1 ;; esac
    ( umask 077; mkdir "$dir" && [ -O "$dir" ] && [ ! -L "$dir" ] && set -C && cat > "$dir/$name" ) || { rm -rf "$dir"; exit 1; }
    printf '%s\n' "$dir"; exit 0 ;;
  unsecret)
    shift; valid_ulid "$1"; rm -rf "$(secret_dir "$1")"; exit 0 ;;
  prune) prune ;;
  *) echo "usage: rx-run.sh begin|go|tail|log|cancel|job|stats|secret|unsecret|prune" >&2; exit 2 ;;
esac
