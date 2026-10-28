#!/usr/bin/env bash
# Builds RMJ from this checkout and installs it the way install.sh installs a release.
set -euo pipefail
cd "$(dirname "$0")/.."

# The commit it is built from, which Settings > About shows.
app=$(scripts/bundle.sh --scratch "${SCRATCH:-$HOME/.cache/rmj-build}" --source "$(git describe --tags --always --dirty)" | tail -1)
exec ./install.sh --app "$app"
