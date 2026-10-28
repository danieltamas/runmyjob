#!/usr/bin/env bash
# Creates "RMJ Local", a self-signed code signing identity in your login keychain, once.
# scripts/bundle.sh signs with it when it exists. Why: an ad-hoc signed build is a new app to
# macOS privacy every time, so each update asks again for every folder an agent touches; a
# build signed by one identity keeps the answers you gave.
# Usage: scripts/make-signing-identity.sh [keychain]   (default: your login keychain)
set -euo pipefail

name="RMJ Local"
keychain=${1:-$HOME/Library/Keychains/login.keychain-db}
# Captured first: grep -q closing the pipe early would fail the pipeline under pipefail.
identities=$(security find-identity -p codesigning "$keychain" || true)
if [[ $identities == *"\"$name\""* ]]; then
  echo "$name already exists."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
# The keychain reads only the older PKCS#12 ciphers; the password lives for this one import.
password=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -out "$work/identity.p12" -passout "pass:$password" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
       -out "$work/identity.p12" -passout "pass:$password"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
echo "Created $name. Next: scripts/install-from-source.sh"
