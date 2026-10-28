#!/usr/bin/env bash
# The gate every change passes: build, the full test suite, the 500-line limit on Swift files, and
# the plain-ASCII-punctuation lint on README.md, docs/ and Sources/.
#   --scratch <dir>  SwiftPM scratch path (default $HOME/.cache/rmj-build; never inside the repo)
#   --root <dir>     the tree to lint (default: this checkout), so tests can lint a fixture
#   --lint-only      skip the build and the tests
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=${SCRATCH:-$HOME/.cache/rmj-build}
root=$repo
lint_only=0
while (($#)); do
  case $1 in
    --scratch) scratch=$2; shift ;;
    --root) root=$2; shift ;;
    --lint-only) lint_only=1 ;;
    *) echo "usage: check.sh [--scratch <dir>] [--root <dir>] [--lint-only]" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$scratch"
case $(cd "$scratch" && pwd -P)/ in
  "$repo"/*) echo "check: the scratch path must be outside the repository" >&2; exit 2 ;;
esac
[[ -d $root ]] || { echo "check: --root $root is not a directory" >&2; exit 2; }
failed=0
fail() { echo "check: $*" >&2; failed=1; }

# A Swift file over 500 lines is split before it is merged.
lint_size() {
  local files file lines
  files=$(find "$root" \( -name .build -o -name build -o -name .git \) -prune -o -name '*.swift' -type f -print0 | tr '\0' '\n') \
    || { fail "cannot list Swift files under $root"; return; }
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    # awk counts a last line that has no trailing newline; wc -l does not.
    lines=$(awk 'END { print NR }' "$file")
    ((lines <= 500)) || fail "${file#"$root"/} has $lines lines (limit 500)"
  done <<< "$files"
}

# En and em dashes, curly quotes, the ellipsis, NBSP and invisible characters read as machine
# text and break copy-paste; user-facing text and docs use - " ' and ... only.
lint_ascii() {
  local targets=() path hits
  for path in README.md docs Sources; do
    [[ -e $root/$path ]] && targets+=("$root/$path")
  done
  ((${#targets[@]})) || return 0
  local list
  list=$(find "${targets[@]}" -type f \( -name '*.md' -o -name '*.swift' \) -print0 | tr '\0' '\n') \
    || { fail "cannot list the files to lint"; return; }
  # A failure of the scan itself fails the gate: only a clean run with no hits passes.
  hits=$(printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 perl -CSD -Mwarnings=FATAL,inplace -ne 'print "$ARGV:$.: non-ASCII punctuation\n" if /[\x{2010}-\x{2015}\x{2018}-\x{201F}\x{2026}\x{00A0}\x{00AD}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}\x{FEFF}]/; close ARGV if eof') \
    || { fail "the punctuation scan failed"; return; }
  if [[ -n $hits ]]; then
    echo "${hits//"$root"\//}" >&2
    fail "non-ASCII punctuation found"
  fi
}

# Every image the README shows (markdown or src=, not a planned one in a comment) exists, and every install.sh option it names is one the script has: a broken
# picture or a command that fails is the first thing a new user meets.
lint_readme() {
  local readme=$root/README.md ref flag
  [[ -f $readme ]] || return 0
  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    [[ -f $root/$ref ]] || fail "README.md shows $ref, which does not exist"
  done < <(grep -oE '(\]\(|src=")docs/media/[A-Za-z0-9._-]+\.png' "$readme" | sed -E 's/^(\]\(|src=")//' | sort -u)
  [[ -f $root/install.sh ]] || return 0
  while IFS= read -r flag; do
    [[ -n $flag ]] || continue
    grep -q -- "$flag" "$root/install.sh" || fail "README.md names install.sh option $flag, which the script does not have"
  done < <(grep -E 'bash -s --|--uninstall|--purge' "$readme" | grep -oE -- '--[a-z-]+' | sort -u | grep -v -- '^--$')
}

# The port from the predecessor app leaves no name of it behind in code, scripts or CI.
lint_leftovers() {
  local path hits status
  for path in Sources Support scripts .github install.sh; do
    [[ -e $root/$path ]] || continue
    # The name is spelled in two pieces so this file does not match itself.
    # grep exits 1 for no match and 2 for a read error: only the first is a clean result.
    # The sibling repository's own slug is data (the shipped tenant table), not a leftover; so is the cross-promotion pane.
    hits=$(grep -rIin -e 'mac''max' "$root/$path" | grep -vi 'danieltamas/mac''max' | grep -v 'Sources/RMJ/MoreAppsPane.swift' | cut -d: -f1 | sort -u; exit "${PIPESTATUS[0]}") && status=0 || status=$?
    ((status <= 1)) || { fail "cannot scan $path for the predecessor name"; continue; }
    [[ -z $hits ]] || fail "leftover predecessor name in: ${hits//"$root"\//}"
  done
}

lint_size
lint_ascii
lint_leftovers
lint_readme

# The box script and profiles embedded in the CLI must match Support/box.
if ((!lint_only)) && [[ -x $repo/scripts/gen-box-assets.sh ]]; then
  before=$(shasum "$repo/Sources/RMJCore/Run/BoxAssets.swift")
  "$repo/scripts/gen-box-assets.sh"
  [[ $before == "$(shasum "$repo/Sources/RMJCore/Run/BoxAssets.swift")" ]] || fail "BoxAssets.swift was stale; regenerated, review and rebuild"
fi

if ((!lint_only)); then
  cd "$repo"
  swift build --build-tests --scratch-path "$scratch" || fail "build failed"
  swift test --skip-build --scratch-path "$scratch" || fail "tests failed"
fi

((!failed)) && echo "check: ok"
exit $failed
