#!/usr/bin/env bash
# Builds RMJ.app from the SwiftPM targets: the app binary, the CLI (Contents/Resources/rmj,
# which the installer copies out), Info.plist and the icons committed in Support. Ad hoc signed.
# --universal builds arm64 and x86_64 and joins them; --version and --build stamp Info.plist,
# --source the commit a build from a checkout comes from (RMJSource, for Settings > About);
# --identity <name>|- picks the signing identity (default: "RMJ Local" when present, else ad hoc);
# --scratch and --out place the build. The source and build paths are remapped in the binaries,
# so where the tree lives leaves no trace in them. Prints the .app path on stdout.
set -euo pipefail
cd "$(dirname "$0")/.."

archs=("$(uname -m)")
version=""
build=""
source=""
scratch=$HOME/.cache/rmj-build-release
out=build
identity=""
while (($#)); do
  case $1 in
    --universal) archs=(arm64 x86_64) ;;
    --version) version=$2; shift ;;
    --build) build=$2; shift ;;
    --source) source=$2; shift ;;
    --scratch) scratch=$2; shift ;;
    --out) out=$2; shift ;;
    --identity) identity=$2; shift ;;
    *) echo "usage: bundle.sh [--universal] [--version <x.y.z> --build <n>] [--source <describe>] [--scratch <dir>] [--out <dir>] [--identity <name>|-]" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$scratch" "$out"
case $(cd "$scratch" && pwd -P)/ in
  "$(pwd -P)"/*) echo "bundle: the scratch path must be outside the repository" >&2; exit 2 ;;
esac
src=$(pwd -P)
scratch=$(cd "$scratch" && pwd -P)
export ZERO_AR_DATE=1

slices=()
for arch in "${archs[@]}"; do
  flags=(-c release --scratch-path "$scratch" --triple "$arch-apple-macosx14.0"
         -Xswiftc -file-prefix-map -Xswiftc "$src=/rmj"
         -Xswiftc -file-prefix-map -Xswiftc "$scratch=/rmj/.build"
         # Without module breadcrumbs the remapped build path is not looked up as a module cache (a wall of warnings).
         -Xswiftc -Xfrontend -Xswiftc -no-clang-module-breadcrumbs)
  swift build "${flags[@]}" >&2
  slices+=("$(swift build "${flags[@]}" --show-bin-path)")
done

app="$out/RMJ.app"
if [[ -d "$app" ]]; then rm -R "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Never `rmj` beside `RMJ`: they are one file on a case-insensitive disk. The CLI lives in
# Resources under its installed name, and is built as RMJCLI for the same reason.
for binary in RMJ RMJCLI; do
  if [[ $binary == RMJ ]]; then dest="$app/Contents/MacOS/RMJ"; else dest="$app/Contents/Resources/rmj"; fi
  lipo -create "${slices[@]/%//$binary}" -output "$dest"
  # SwiftPM adds the toolchain's own library folder as an rpath. Nothing loads from it (the
  # Swift runtime is the OS's), and it would tie the bytes to where Xcode is installed.
  otool -l "$dest" | awk '$1 == "path" { print $2 }' | sort -u \
    | { grep '\.xctoolchain/' || true; } | while read -r rpath; do
      install_name_tool -delete_rpath "$rpath" "$dest" 2>/dev/null
    done
  # Debug symbols name each object file with its build time; the release carries none.
  strip -S "$dest" 2>/dev/null
done
cp Support/Info.plist "$app/Contents/Info.plist"
if [[ -n $version ]]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "${build:-1}" "$app/Contents/Info.plist"
fi
if [[ -n $source ]]; then
  plutil -replace RMJSource -string "$source" "$app/Contents/Info.plist"
fi
cp Support/AppIcon.icns Support/MenuBarIcon.pdf "$app/Contents/Resources/"
# What setup puts on a box: the runner stack and the rx image Dockerfiles.
mkdir -p "$app/Contents/Resources/box"
cp -R Support/Registry "$app/Contents/Resources/"
cp -R Support/runner-stack "$app/Contents/Resources/runner-stack"
cp -R Support/box/images "$app/Contents/Resources/box/images"
# About's Update runs the same installer as the curl line, pinned to the release it showed.
install -m 755 install.sh "$app/Contents/Resources/install.sh"

# Ad-hoc unless this Mac has "RMJ Local" (scripts/make-signing-identity.sh): an ad-hoc build is a
# new app to macOS privacy every time. A release stays ad-hoc so two builds match byte for byte.
if [[ -z $identity ]]; then
  identity=-
  # Captured first: grep -q closing the pipe early would fail the pipeline under pipefail.
  identities=$(security find-identity -p codesigning 2>/dev/null || true)
  if [[ -z $version && $identities == *'"RMJ Local"'* ]]; then identity="RMJ Local"; fi
fi
codesign --force --sign "$identity" "$app/Contents/Resources/rmj"
codesign --force --sign "$identity" "$app"
echo "$app"
