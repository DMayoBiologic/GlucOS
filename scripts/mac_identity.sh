#!/bin/bash
# Finds the Developer ID Application identity the Mac app is signed with, and puts it in a
# throwaway keychain for xcodebuild/codesign. Writes `identity` and `team` to $GITHUB_OUTPUT.
#
# Why it matters: an ad-hoc signature is just a hash of the build, so the login keychain treats
# every Sparkle update as a new app and asks for the Keychain password again. A Developer ID
# signature keeps the same Team ID across builds, so one "Always Allow" (and the re-saved items,
# see Sources/App/Keychain.swift) lasts.
#
# Where the identity comes from, first match wins:
#   1. MACOS_CERTIFICATE_P12 / MACOS_CERTIFICATE_PASSWORD secrets, if someone set them.
#   2. The sealed identity CI made earlier: asset developer-id.p12.enc on the `mac-signing`
#      release (a prerelease, never "latest", so Sparkle's feed ignores it). It is encrypted with
#      a key derived from the SPARKLE_PRIVATE_KEY secret, so the asset alone is useless.
#   3. With MINT=true: a new key made here, a Developer ID certificate from Apple through the App
#      Store Connect API key (scripts/asc_developer_id.py), sealed and uploaded as in 2. This
#      happens once; every later run takes path 2. Nobody has to do anything by hand.
# If none works the app is ad-hoc signed as before, with a warning. But once a sealed identity
# exists, failing to open it fails the run: an ad-hoc release after a signed one would ask for
# the Keychain password again.
#
# Env: P12, P12_PASSWORD (optional); SEAL (SPARKLE_PRIVATE_KEY); KEY_P8, KEY_ID, ISSUER;
#      GH_TOKEN (contents: write to publish the sealed identity); REPO (owner/name); MINT.
set -euo pipefail

TAG=mac-signing
ASSET=developer-id.p12.enc
OUT=${GITHUB_OUTPUT:-/dev/stdout}
W="${RUNNER_TEMP:-$(mktemp -d)}/macid"
rm -rf "$W" && mkdir -p "$W" && chmod 700 "$W"
SSL=/usr/bin/openssl   # LibreSSL: its .p12 files import into the macOS keychain without -legacy.

adhoc() {
  echo "::warning::$1 Signing ad-hoc, so this update may ask for the Keychain password again."
  echo "identity=-" >> "$OUT"; echo "team=" >> "$OUT"
  exit 0
}

if [ -n "${P12:-}" ]; then
  printf '%s' "$P12" | base64 --decode > "$W/id.p12"
  PASS="${P12_PASSWORD:-}"
else
  [ -n "${SEAL:-}" ] || adhoc "No SPARKLE_PRIVATE_KEY to seal a signing identity with."
  PASS=$(printf 'glucos-developer-id-v1:%s' "$SEAL" | shasum -a 256 | cut -c1-64)
  export PASS

  fetch() { gh release download "$TAG" -R "$REPO" -p "$ASSET" -D "$W" --clobber >/dev/null 2>&1; }
  unseal() {
    "$SSL" enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:PASS -in "$W/$ASSET" -out "$W/id.p12" \
      || { echo "::error::Can't open the sealed Developer ID identity ($ASSET on the $TAG release). Was SPARKLE_PRIVATE_KEY changed? Delete that release to have CI make a new identity."; exit 1; }
  }

  if fetch; then
    echo "Using the sealed Developer ID identity from the $TAG release."
    unseal
  else
    [ "${MINT:-false}" = true ] || adhoc "No Developer ID identity yet, and this run doesn't make one."
    [ -n "${KEY_P8:-}" ] && [ -n "${KEY_ID:-}" ] && [ -n "${ISSUER:-}" ] \
      || adhoc "No App Store Connect API key to ask Apple for a Developer ID certificate."
    echo "No Developer ID identity yet: asking Apple for one."
    "$SSL" req -new -newkey rsa:2048 -nodes -keyout "$W/key.pem" -out "$W/csr.pem" \
      -subj "/CN=GlucOS release signing/O=GlucOS" 2>/dev/null
    python3 -m pip install --quiet 'pyjwt[crypto]==2.10.1' >/dev/null 2>&1 \
      || python3 -m pip install --quiet --break-system-packages 'pyjwt[crypto]==2.10.1'
    set +e
    python3 "$(dirname "$0")/asc_developer_id.py" --csr "$W/csr.pem" --out "$W/cert.der"
    RC=$?
    set -e
    [ $RC -eq 0 ] || adhoc "Apple didn't issue a Developer ID certificate (see above)."
    "$SSL" x509 -inform der -in "$W/cert.der" -out "$W/cert.pem"
    "$SSL" pkcs12 -export -inkey "$W/key.pem" -in "$W/cert.pem" -name "GlucOS Developer ID" \
      -passout env:PASS -out "$W/id.p12"
    rm -f "$W/key.pem"
    "$SSL" enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -pass env:PASS -in "$W/id.p12" -out "$W/$ASSET"
    gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || gh release create "$TAG" -R "$REPO" \
      --prerelease --latest=false --title "Mac signing identity (CI only)" \
      --notes "Encrypted Developer ID identity that CI signs the Mac app with (scripts/mac_identity.sh). Not an app release: don't download it, and don't delete it unless you want CI to make a new identity."
    if ! gh release upload "$TAG" -R "$REPO" "$W/$ASSET"; then
      # Another run sealed one first: use that, so every build carries the same identity.
      echo "Another run published an identity first; using that one."
      fetch || { echo "::error::Couldn't publish or fetch the sealed identity."; exit 1; }
      unseal
    fi
  fi
fi

KC="$W/build.keychain-db"
security create-keychain -p actions "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p actions "$KC"
security import "$W/id.p12" -P "$PASS" -A -t cert -f pkcs12 -k "$KC"
# The intermediates, in case the runner image lacks them (codesign needs the whole chain).
for CA in DeveloperIDG2CA DeveloperIDCA; do
  curl -fsSL "https://www.apple.com/certificateauthority/$CA.cer" -o "$W/$CA.cer" \
    && security import "$W/$CA.cer" -k "$KC" >/dev/null 2>&1 || true
done
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k actions "$KC" >/dev/null
security list-keychains -d user -s "$KC" login.keychain-db
rm -f "$W/id.p12"

ID=$(security find-identity -v -p codesigning "$KC" | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
[ -n "$ID" ] || { echo "::error::The identity imported, but it isn't a valid Developer ID Application identity."; security find-identity -p codesigning "$KC"; exit 1; }
TEAM=$(echo "$ID" | grep -oE '\([A-Z0-9]{10}\)' | tail -1 | tr -d '()')
echo "Signing as: $ID"
echo "identity=$ID" >> "$OUT"
echo "team=$TEAM" >> "$OUT"
