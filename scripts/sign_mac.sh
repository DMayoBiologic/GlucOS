#!/bin/bash
# Builds GlucOS.app for release, Developer ID signed. Used by release.yml and by mac-signing.yml
# (which checks a pull request's signing before it can reach main).
#
# The certificate comes from MACOS_CERTIFICATE_P12 / MACOS_CERTIFICATE_PASSWORD (a base64 .p12 of
# a "Developer ID Application" certificate and its key). App Store Connect API keys can't use
# Apple's cloud-managed Developer ID certificate ("Cloud signing permission error"), so the
# certificate has to be a real one; the API key still makes the provisioning profile.
#
# Why it matters: macOS ties Keychain access to the app's code signature. Ad-hoc builds got a
# new signature every release, so after each Sparkle update macOS asked for the login password
# before GlucOS could read its saved logins. A Developer ID signature is the same from release
# to release (Team ID + bundle ID), and the keychain-access-groups entitlement added here lets
# the app use the data protection keychain, where that's all that matters.
#
# Needs: MACOS_CERTIFICATE_P12, MACOS_CERTIFICATE_PASSWORD, TEAM_ID, KEY_ID, ISSUER, KEY_P8 (App Store Connect API key, Admin role, the same one the
# iPhone release uses), VERSION, BUILD_NUMBER, SPARKLE_PUBLIC_ED_KEY. Run after `xcodegen generate`.
# Leaves the signed app at $OUT/GlucOS.app (OUT defaults to build/export).
set -euo pipefail

: "${MACOS_CERTIFICATE_P12:?}" "${MACOS_CERTIFICATE_PASSWORD:?}" "${TEAM_ID:?}" "${KEY_ID:?}" "${ISSUER:?}" "${KEY_P8:?}" "${VERSION:?}" "${BUILD_NUMBER:?}" "${SPARKLE_PUBLIC_ED_KEY:?}"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
OUT="${OUT:-build/export}"
ARCHIVE="$TMP/GlucOS-mac.xcarchive"
KEY="$TMP/AuthKey_mac.p8"
GROUP="$TEAM_ID.au.com.declanmayo.glucos"
ENT=Sources/App/GlucOS.entitlements   # written by xcodegen from project.yml

printf '%s\n' "$KEY_P8" > "$KEY"
KC="$TMP/glucos-signing.keychain-db"
trap 'rm -f "$KEY" "$TMP/cert.p12"; security delete-keychain "$KC" 2>/dev/null || true' EXIT

# A throwaway keychain holding just the Developer ID identity, searched ahead of the login one.
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p glucos "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p glucos "$KC"
printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$TMP/cert.p12"
security import "$TMP/cert.p12" -P "$MACOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KC" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k glucos "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$KC" | grep -q "Developer ID Application" \
  || { echo "::error::MACOS_CERTIFICATE_P12 has no Developer ID Application identity"; exit 1; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

# Only release builds get the keychain group: it needs a provisioning profile, which an ad-hoc
# local build can't have (macOS would refuse to launch it).
test -f "$ENT" || { echo "::error::$ENT not found. Run xcodegen generate first."; exit 1; }
plutil -remove keychain-access-groups "$ENT" >/dev/null 2>&1 || true
plutil -insert keychain-access-groups -json "[\"$GROUP\"]" "$ENT"

# Archive signed to run locally; the export below re-signs everything with Developer ID. Signing
# the archive with automatic signing would create a new Apple Development certificate on every
# run (the runner's keychain is thrown away), and Apple caps how many an account can have.
set +e
xcodebuild -project GlucOS.xcodeproj -scheme GlucOS -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="$TEAM_ID" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  archive > "$TMP/archive-mac.log" 2>&1
set -e
if ! grep -q "ARCHIVE SUCCEEDED" "$TMP/archive-mac.log"; then
  echo "::error::Mac archive failed"; grep -E "error:" "$TMP/archive-mac.log" | sort -u; tail -30 "$TMP/archive-mac.log"; exit 1
fi

cat > "$TMP/ExportOptions-mac.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
rm -rf "$OUT"
set +e
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$TMP/ExportOptions-mac.plist" \
  -exportPath "$OUT" "${AUTH[@]}" > "$TMP/export-mac.log" 2>&1
CODE=$?
set -e
if [ $CODE -ne 0 ] || [ ! -d "$OUT/GlucOS.app" ]; then
  echo "::error::Developer ID export failed"; grep -iE "error" "$TMP/export-mac.log" | sort -u; tail -30 "$TMP/export-mac.log"
  exit 1
fi

APP="$OUT/GlucOS.app"
codesign --verify --deep --strict "$APP"
REQ=$(codesign -d -r- "$APP" 2>&1)
echo "$REQ" | grep -qE "certificate leaf\[subject.OU\] = \"?$TEAM_ID" \
  || { echo "::error::GlucOS.app isn't Developer ID signed for $TEAM_ID:"; echo "$REQ"; exit 1; }
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "$GROUP" \
  || { echo "::error::GlucOS.app is missing its keychain access group, so the app would fall back to the login keychain and prompt after updates"; exit 1; }
test -f "$APP/Contents/embedded.provisionprofile" \
  || { echo "::error::GlucOS.app has no provisioning profile, so macOS would refuse its keychain entitlement"; exit 1; }
echo "Signed: $(codesign -dvv "$APP" 2>&1 | grep -E '^Authority=' | head -1)"
echo "$REQ" | sed -n 's/^designated => /Designated requirement: /p'
