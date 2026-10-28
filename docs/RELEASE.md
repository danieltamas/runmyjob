# Release

RMJ ships as GitHub releases of one ad hoc signed, universal zip. There is no Developer ID: the app is not
notarized, so a zip downloaded in a browser is blocked on first open until it is allowed in System Settings >
Privacy & Security; `install.sh` and the Homebrew cask fetch it without the quarantine flag. Because the signature is
ad hoc the build is reproducible: anyone can build the tag and compare bytes.

## Versions
Semantic, `0.x.y` until the owner calls 1.0. Tag `vX.Y.Z` (annotated) on `main`. `CFBundleShortVersionString` is
`X.Y.Z`, `CFBundleVersion` is `git rev-list --count HEAD`. `Support/toolchain` pins the Xcode build; changing it is its
own commit.

## Scripts
- `scripts/release.sh <X.Y.Z> [--verify] [--out dir] [--ref rev]` builds `RMJ-X.Y.Z.zip` and `SHA256SUMS` from a clean
  export of the tag. `--verify` builds twice elsewhere and fails on one differing byte. `--ref` is a trial run and says
  it is not a release.
- `scripts/acceptance.sh [check|live|faults|perf|mcp|release]` is the gate (docs/PLAN.md, "Measured by"). `live` needs
  `RMJ_LIVE_DESTINATION`; `release` verifies the newest tag and installs it with `install.sh` into a scratch folder.
- `scripts/perf.sh [seconds]` measures the app's CPU, idle and while a job streams.
- `scripts/tap.sh <X.Y.Z>` pins the Homebrew cask (`danieltamas/homebrew-tap`, `Casks/rmj.rb`) to the published zip.

## Ceremony (only when the owner chooses a release)
1. `scripts/acceptance.sh check faults mcp perf` on `main`, clean tree, LOG.md entry written.
2. `git tag -a vX.Y.Z`, `scripts/release.sh X.Y.Z --verify`.
3. Owner pushes the tag; `release-verify` rebuilds it in CI (neutral when the runner lacks the pinned Xcode).
4. Owner creates the GitHub release with `dist/RMJ-X.Y.Z.zip` and `dist/SHA256SUMS`; notes name the s1 (second company)
   scenario as pending and record the manual check: a failed job's log opened from its notification.
5. `RMJ_VERSION=X.Y.Z ./install.sh` on a clean user, then `scripts/tap.sh X.Y.Z`.
6. `scripts/acceptance.sh release`.
7. Announce the release to the registry (last step; a failed ping is not a failed release, the registry's hourly
   refresh picks it up). Needs `gh` logged in as the owner:
   ```
   gh api repos/danieltamas/registry/dispatches -f event_type=release
   for i in $(seq 18); do v=$(gh api repos/danieltamas/registry/contents/apps.json --jq '.content | @base64d | fromjson | .apps[] | select(.repo == "danieltamas/runmyjob") | .latest.version'); test "$v" = "X.Y.Z" && exit 0; sleep 10; done; echo "registry shows ${v:-no release} for danieltamas/runmyjob, not X.Y.Z"; exit 1
   ```
   Before a release, `scripts/registry-snapshot.sh` refreshes the bundled copy (`Support/Registry`, its registry
   commit in `COMMIT`); commit the result.

## Status
Prepared and verified locally: the reproducible build (two builds identical), the MCP smoke test, the scripts above.
Not done: the registry ping and its confirmation have never run (there is no release to check them against); the repository is not public, there is no tag, the cask repository does not exist, `live` and the 10-minute
idle `perf` run are not recorded.
