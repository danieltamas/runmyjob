#!/usr/bin/env bash
# The release gate (docs/PLAN.md, "Measured by"): runs the steps in order and stops at the first failure.
#   acceptance.sh [check|live|faults|perf|mcp|release] ...   (no argument: every step, 1 to 6)
#   RMJ_LIVE_DESTINATION=<ssh alias>   the box the live step uses (required for `live`)
#   RMJ_VERSION=<X.Y.Z>                the version `release` verifies and installs (default: the latest tag)
#   SCRATCH                            SwiftPM scratch path (default $HOME/.cache/rmj-build)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repo"
scratch=${SCRATCH:-$HOME/.cache/rmj-build}
cli=$scratch/debug/RMJCLI

step() { echo "acceptance: $*"; }
fail() { echo "acceptance: $*" >&2; exit 1; }
built() { [[ -x $cli ]] || fail "build first: $cli is missing (swift build --scratch-path $scratch)"; }

# 1. Build, the full suite, the size and ASCII lint.
check() { step "1/6 check"; scripts/check.sh --scratch "$scratch"; }

# 2. The real tailnet and one real box. Never a Globex box (docs/PLAN.md, U13).
live() {
  step "2/6 live"
  [[ -n ${RMJ_LIVE_DESTINATION:-} ]] || fail "set RMJ_LIVE_DESTINATION to the ssh alias of the live box"
  RMJ_LIVE=1 arch -arm64 swift test --skip-build --scratch-path "$scratch" --filter Live
}

# 3. Every failure mode against fixtures (RMJ_TAILSCALE_FIXTURE, the box fixtures of the run tests): tailnet stopped,
# peer offline, address outside the tailnet, ssh timeout, start-failed, exit 125 after start, killed client then
# reconcile, a rebooted box, two runs of one worktree, a tenant mismatch, a rules file with an error.
faults() {
  step "3/6 faults"
  arch -arm64 swift test --skip-build --scratch-path "$scratch" \
    --filter 'TailnetAcceptance|RunAcceptance|RunReconcileAcceptance|RunSupportAcceptance|TenancyAcceptance|RoutingAcceptance|RulesAcceptance|OpsHeartbeatAcceptance'
}

# 4. Idle and streaming CPU of the installed app.
perf() { step "4/6 perf"; scripts/perf.sh; }

# 5. The MCP server over stdio: initialize, tools/list and every tool, JSON-RPC only on stdout, each within 500 ms.
mcp() {
  step "5/6 mcp"
  built
  local home out
  home=$(mktemp -d); chmod 700 "$home"
  trap 'rm -rf "$home"' RETURN
  printf '{"agent_access": true}\n' > "$home/config.json"
  out=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"destinations","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"jobs","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"failures","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope","arguments":{}}}' \
    | RMJ_HOME="$home" /usr/bin/python3 -I "$repo/scripts/mcp-smoke.py" "$cli")
  echo "$out"
}

# 6. The tag builds twice to the same bytes, and the published release installs.
release() {
  step "6/6 release"
  local version=${RMJ_VERSION:-}
  [[ -n $version ]] || version=$(git describe --tags --abbrev=0 | sed 's/^v//')
  scripts/release.sh "$version" --verify
  RMJ_VERSION=$version RMJ_INSTALL_ROOT=$(mktemp -d) ./install.sh
}

all() { check; live; faults; perf; mcp; release; echo "acceptance: ok"; }

if (($# == 0)); then all; else for s in "$@"; do "$s"; done; fi
