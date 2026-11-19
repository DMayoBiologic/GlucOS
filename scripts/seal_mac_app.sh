#!/bin/bash
# Re-signs Sparkle's helpers and the app with the Developer ID identity, then checks the result.
# xcodebuild signs our own targets, but leaves the helpers inside Sparkle.framework with the
# signature they shipped with; Developer ID (and notarization) want every piece signed by us,
# with the hardened runtime and a timestamp. Ad-hoc builds (ID "-") are only verified.
#
#   scripts/seal_mac_app.sh path/to/GlucOS.app "Developer ID Application: … (TEAMID)" TEAMID
set -euo pipefail
APP="$1"; ID="$2"; TEAM="${3:-}"

if [ "$ID" != "-" ]; then
  sign() { codesign --force --sign "$ID" --options runtime --timestamp --preserve-metadata=entitlements "$@"; }
  F="$APP/Contents/Frameworks/Sparkle.framework"
  if [ -d "$F" ]; then
    V="$F/Versions/Current"
    for X in "$V"/XPCServices/*.xpc "$V/Autoupdate" "$V/Updater.app"; do
      [ -e "$X" ] && sign "$X"
    done
    sign "$F"
  fi
  # Our own nested code first, then the app itself, so each seal covers the pieces inside it.
  for X in "$APP"/Contents/PlugIns/*.appex; do [ -e "$X" ] && sign "$X"; done
  sign "$APP"
fi

codesign --verify --deep --strict "$APP"
if [ "$ID" != "-" ]; then
  GOT=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ "$GOT" = "$TEAM" ] || { echo "::error::App signed with Team ID '$GOT', expected '$TEAM'"; exit 1; }
  codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
  echo "Signed with Developer ID, Team ID $GOT"
fi
