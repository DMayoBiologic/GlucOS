#!/usr/bin/env python3
"""Turns on the App ID capabilities that an archived app's entitlements need.

Cloud signing at export makes App Store profiles from each App ID's capabilities, and a profile
without a capability the app claims fails the export. Xcode's automatic signing used to switch
capabilities on while archiving. The archive is now signed locally (scripts/sign_ios.sh), so
this does that part: for every .app/.appex in the archive, it reads the entitlements and enables
what's missing through the App Store Connect API. App Groups stay manual: the API can't assign a
group to an App ID (docs/iOS.md, step 2).

Usage: asc_capabilities.py <path to .xcarchive>. Needs KEY_ID, ISSUER, KEY_P8.
"""
import os
import plistlib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
from testflight_external import call  # noqa: E402

# Entitlement key → App Store Connect capability type.
CAPABILITIES = {
    "aps-environment": "PUSH_NOTIFICATIONS",
    "com.apple.developer.nfc.readersession.formats": "NFC_TAG_READING",
    "com.apple.developer.usernotifications.time-sensitive": "USERNOTIFICATIONS_TIMESENSITIVE",
}


def bundles(archive):
    apps = Path(archive, "Products", "Applications")
    for app in apps.glob("*.app"):
        yield app
        yield from app.glob("PlugIns/*.appex")


def entitlements(bundle):
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
                         capture_output=True).stdout
    return plistlib.loads(out) if out.strip() else {}


def main():
    for b in bundles(sys.argv[1]):
        ident = plistlib.loads(Path(b, "Info.plist").read_bytes())["CFBundleIdentifier"]
        wanted = {CAPABILITIES[k] for k in entitlements(b) if k in CAPABILITIES}
        if not wanted:
            continue
        found = call("GET", "/bundleIds", params={"filter[identifier]": ident, "limit": 200})
        match = [d for d in found.get("data", []) if d["attributes"]["identifier"] == ident]
        if not match:
            print(f"::warning::No App ID for {ident}; Xcode registers it during export.")
            continue
        bid = match[0]["id"]
        have = {c["attributes"].get("capabilityType")
                for c in call("GET", f"/bundleIds/{bid}/bundleIdCapabilities").get("data", [])}
        for cap in sorted(wanted - have):
            call("POST", "/bundleIdCapabilities", body={"data": {
                "type": "bundleIdCapabilities",
                "attributes": {"capabilityType": cap},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}},
            }})
            print(f"Enabled {cap} on {ident}")
        print(f"{ident}: {', '.join(sorted(wanted))} on")


if __name__ == "__main__":
    main()
