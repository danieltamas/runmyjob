#!/usr/bin/env bash
# Copies the app registry (github.com/danieltamas/registry) into Support/Registry: apps.json and the icons it
# names. The bundle ships this copy, so Settings > More apps is full on first launch and offline; the app reads
# the live file when the pane opens. Run before a release and commit the result.
#
#   scripts/registry-snapshot.sh [ref]     ref: a commit, tag or branch of the registry (default main)
set -euo pipefail

ref=${1:-main}
repo=danieltamas/registry
root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/Support/Registry
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

commit=$(gh api "repos/$repo/commits/$ref" --jq .sha)
raw() { gh api -H "Accept: application/vnd.github.raw" "repos/$repo/contents/$1?ref=$commit" > "$work/$1"; }

mkdir -p "$work/icons"
raw apps.json
for icon in $(python3 -c '
import json, re, sys
for app in json.load(open(sys.argv[1]))["apps"]:
    icon = app.get("icon", "")
    if re.fullmatch(r"icons/[a-z0-9-]+\.png", icon):
        print(icon)
' "$work/apps.json"); do
  raw "$icon"
done

rm -rf "$out"
mkdir -p "$out"
cp -R "$work/apps.json" "$work/icons" "$out/"
echo "$commit" > "$out/COMMIT"
echo "registry-snapshot: $repo@${commit:0:7} -> Support/Registry ($(ls "$out/icons" | wc -l | tr -d ' ') icons)"
