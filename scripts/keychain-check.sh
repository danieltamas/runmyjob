#!/usr/bin/env bash
# Decision D7: can the app and the CLI read the same Keychain item, also after an update?
# Since 2026-10-31 Keychain.swift writes and reads through /usr/bin/security, and an item it creates
# trusts that Apple binary, so the answer must be "shared": a run that says "not shared" means the
# trust model regressed (an item bound to RMJ's own signature, which an ad hoc update invalidates).
# Runs the real binaries of an installed (or just built) RMJ.app, copied into a temporary
# directory so nothing installed is touched:
#   1. the CLI writes the item `rmj.test`, naming the app binary as trusted too;
#   2. the app and the CLI each read it;
#   3. an update is simulated (Info.plist version bumped, bundle signed again, same identity);
#   4. the app and the CLI each read it again.
# A read that would make macOS show an allow/deny dialog fails fast instead (exit 4 of the
# probe); a probe that hangs is killed after 20 s and counts as a prompt too.
# Exit 0: a conclusion was reached. The last line says "shared" (both read it before and after the
# update) or "not shared" (a regression, see above). Exit 1: a probe failed in an unexpected way. Exit 2: usage or setup problem.
# The login keychain is written (one item, removed at the end).
#   --app <RMJ.app>  the bundle to test (default: the installed one, else build/RMJ.app)
#   --identity <n>   signing identity (default: ad hoc, which is what a release is signed with;
#                    "RMJ Local" shows what a stable identity changes)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
app=""
identity=""
while (($#)); do
  case $1 in
    --app) app=$2; shift ;;
    --identity) identity=$2; shift ;;
    *) echo "usage: keychain-check.sh [--app <RMJ.app>] [--identity <name>|-]" >&2; exit 2 ;;
  esac
  shift
done
if [[ -z $app ]]; then
  for candidate in /Applications/RMJ.app "$HOME/Applications/RMJ.app" "$repo/build/RMJ.app"; do
    [[ -d $candidate ]] && { app=$candidate; break; }
  done
fi
[[ -d $app ]] || { echo "keychain-check: no RMJ.app found: scripts/install-from-source.sh first" >&2; exit 2; }
if [[ -z $identity ]]; then
  identity=-
fi

work=$(mktemp -d)
account=rmj.test.$$
copy=$work/RMJ.app
app_binary=$copy/Contents/MacOS/RMJ
cli_binary=$copy/Contents/Resources/rmj
cleanup() {
  local removed=0
  if [[ -x $cli_binary ]]; then removed=$(probe "$cli_binary" remove "$account"); fi
  rm -rf "$work"
  if ((removed != 0)); then
    echo "keychain-check: could not remove the test item $account (status $removed): delete it in Keychain Access" >&2
    exit 1
  fi
}
trap cleanup EXIT
ditto "$app" "$copy"
sign() {
  codesign --force --sign "$identity" ${1:+--entitlements "$1"} "$cli_binary"
  codesign --force --sign "$identity" ${1:+--entitlements "$1"} "$copy"
}

# probe <binary> <args...>: prints the exit status; 142 is a probe killed after 20 s (SIGKILL).
probe() {
  local binary=$1 status=0
  shift
  RMJ_KEYCHAIN_PROBE=1 /usr/bin/perl -e 'my $p = fork; exec @ARGV unless $p; $SIG{ALRM} = sub { kill 9, $p; waitpid $p, 0; exit 142 }; alarm 20; waitpid $p, 0; exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' -- "$binary" --keychain-probe "$@" >/dev/null 2>&1 || status=$?
  echo "$status"
}

failed=0
refused=0
expect_read() {
  local label=$1 binary=$2 status
  status=$(probe "$binary" read "$account")
  case $status in
    0) echo "ok       $label reads $account" ;;
    4) echo "REFUSED  $label cannot read $account without a prompt"; refused=1 ;;
    142) echo "ERROR    $label read $account hung (killed after 20 s): not a verdict"; failed=1 ;;
    *) echo "ERROR    $label read $account: status $status"; failed=1 ;;
  esac
}

echo "bundle   $app"
echo "identity $identity"
sign
status=$(probe "$cli_binary" write "$account" "rmj-test-secret" "$app_binary")
[[ $status == 0 ]] || { echo "keychain-check: cannot write the test item (status $status)" >&2; exit 2; }
echo "-- installed build"
expect_read "app" "$app_binary"
expect_read "cli" "$cli_binary"
# An entitlements blob changes both code directories (a new cdhash) and keeps the identifier and
# the certificate, which is what a new build of the same app looks like to the Keychain.
plutil -replace CFBundleVersion -string "update-$$" "$copy/Contents/Info.plist"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$work/update.entitlements"
sign "$work/update.entitlements"
echo "-- after an update (new build, same identity)"
expect_read "app" "$app_binary"
expect_read "cli" "$cli_binary"

((failed)) && { echo "keychain-check: a probe failed unexpectedly" >&2; exit 1; }
if ((refused)); then
  echo "keychain-check: NOT shared with identity '$identity': macOS asked for approval. Keychain.swift must go through /usr/bin/security so the item trusts it and not RMJ's own signature."
  exit 1
else
  echo "keychain-check: shared across an update with identity '$identity'"
fi
