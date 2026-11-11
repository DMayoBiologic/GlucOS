#!/bin/bash
# Archives the iPhone app and signs it for the App Store with Apple's cloud-managed distribution
# certificate, so CI never creates a certificate. Used by release.yml (DESTINATION=upload, sends it
# to App Store Connect) and by ios-signing.yml (DESTINATION=export, checks a pull request's signing
# without uploading anything).
#
# Why: the archive used to be signed with automatic "Apple Development" signing. A CI runner's
# keychain is thrown away after every run, so Xcode made a new development certificate each time,
# until the account hit Apple's cap and archives failed ("Your account has reached the maximum
# number of certificates"). Now the archive is signed to run locally (ad-hoc, which keeps the
# entitlements in it) and -exportArchive re-signs it in the cloud. Same idea as scripts/sign_mac.sh.
#
# Needs: TEAM_ID, KEY_ID, ISSUER, KEY_P8 (App Store Connect API key, Admin role), VERSION,
# BUILD_NUMBER, RELAY_URL. Run after `xcodegen generate`. DESTINATION is upload or export
# (default export); an exported .ipa lands in $OUT (default build/export-ios).
set -euo pipefail

: "${TEAM_ID:?}" "${KEY_ID:?}" "${ISSUER:?}" "${KEY_P8:?}" "${VERSION:?}" "${BUILD_NUMBER:?}" "${RELAY_URL:?}"
DESTINATION="${DESTINATION:-export}"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
OUT="${OUT:-build/export-ios}"
ARCHIVE="$TMP/GlucOS-ios.xcarchive"
KEY="$TMP/AuthKey_ios.p8"
APP_GROUP="group.au.com.declanmayo.glucos"

printf '%s\n' "$KEY_P8" > "$KEY"
trap 'rm -f "$KEY"' EXIT
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

# No -allowProvisioningUpdates here: the archive needs no certificate or profile from Apple.
set +e
xcodebuild -project GlucOS.xcodeproj -scheme GlucOSiOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath build-ios -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
  PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  GLUCOS_RELAY_URL="$RELAY_URL" \
  archive > "$TMP/archive-ios.log" 2>&1
set -e
if ! grep -q "ARCHIVE SUCCEEDED" "$TMP/archive-ios.log"; then
  echo "::error::iOS archive failed"; grep -E "error:" "$TMP/archive-ios.log" | sort -u; tail -30 "$TMP/archive-ios.log"; exit 1
fi

cat > "$TMP/ExportOptions-ios.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
rm -rf "$OUT"
set +e
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$TMP/ExportOptions-ios.plist" \
  -exportPath "$OUT" "${AUTH[@]}" > "$TMP/export-ios.log" 2>&1
CODE=$?
set -e
if [ $CODE -ne 0 ]; then
  echo "::error::iOS export failed"; grep -iE "error" "$TMP/export-ios.log" | sort -u; tail -30 "$TMP/export-ios.log"
  # Apple's API can register an App ID but can't assign it an App Group.
  if grep -q "application-groups" "$TMP/export-ios.log"; then
    echo "::error::An App ID is missing its App Group. Tick App Groups on it in the developer portal (docs/iOS.md, step 2)."
  fi
  if grep -qi "certificate" "$TMP/export-ios.log"; then
    echo "::error::Cloud signing needs an Admin-role App Store Connect API key (docs/iOS.md)."
  fi
  exit 1
fi

if [ "$DESTINATION" = export ]; then
  IPA=$(ls "$OUT"/*.ipa | head -1)
  rm -rf "$TMP/ipa" && mkdir -p "$TMP/ipa" && ditto -x -k "$IPA" "$TMP/ipa"
  for B in "$TMP"/ipa/Payload/*.app "$TMP"/ipa/Payload/*.app/PlugIns/*.appex; do
    NAME=$(basename "$B")
    AUTHORITY=$(codesign -dvv "$B" 2>&1 | grep -E '^Authority=' | head -1)
    echo "$NAME: $AUTHORITY"
    echo "$AUTHORITY" | grep -q "Apple Distribution" \
      || { echo "::error::$NAME isn't signed with an Apple Distribution certificate"; exit 1; }
    test -f "$B/embedded.mobileprovision" || { echo "::error::$NAME has no provisioning profile"; exit 1; }
    codesign -d --entitlements - --xml "$B" 2>/dev/null | grep -q "$APP_GROUP" \
      || { echo "::error::$NAME lost its App Group entitlement in signing"; exit 1; }
  done
else
  echo "Uploaded GlucOS $VERSION ($BUILD_NUMBER) to App Store Connect; TestFlight has it once Apple finishes processing."
fi
