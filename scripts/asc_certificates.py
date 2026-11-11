#!/usr/bin/env python3
"""Lists the team's signing certificates, and can revoke the development ones CI made.

Before scripts/sign_ios.sh, every iPhone release made a new "Apple Development" certificate on a
throwaway runner, until the account hit Apple's cap. This prints what's there so the leftovers can
be seen, and with --revoke-ci-development revokes only development certificates that the App Store
Connect API created (Xcode names those "Created via API"). Certificates made in Xcode on a Mac,
distribution certificates and Developer ID certificates are never touched.

Needs KEY_ID, ISSUER, KEY_P8 (the App Store Connect API key). Uses the helpers in
testflight_external.py.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from testflight_external import call  # noqa: E402

DEVELOPMENT_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT", "MAC_APP_DEVELOPMENT"}


def certificates():
    out, path, params = [], "/certificates", {"limit": 200}
    while path:
        page = call("GET", path, params=params)
        out += page.get("data", [])
        nxt = page.get("links", {}).get("next")
        # The next link is absolute; call() wants a path under the API root.
        path = nxt.split("/v1", 1)[1] if nxt else None
        params = None
    return out


def made_by_ci(cert):
    a = cert["attributes"]
    text = f'{a.get("name", "")} {a.get("displayName", "")}'
    return a.get("certificateType") in DEVELOPMENT_TYPES and "Created via API" in text


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--revoke-ci-development", action="store_true",
                   help="revoke development certificates created through the API (by CI)")
    args = p.parse_args()

    certs = sorted(certificates(), key=lambda c: (c["attributes"].get("certificateType", ""),
                                                  c["attributes"].get("expirationDate", "")))
    ci = [c for c in certs if made_by_ci(c)]
    print(f"{len(certs)} certificates, {len(ci)} of them development certificates made by CI:")
    for c in certs:
        a = c["attributes"]
        mark = "  [CI]" if c in ci else ""
        print(f'  {a.get("certificateType", "?"):24} {a.get("expirationDate", "?")[:10]}  '
              f'{a.get("name", "")} / {a.get("displayName", "")}  {c["id"]}{mark}')

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"**Signing certificates:** {len(certs)} in total, {len(ci)} development "
                    f"certificates made by CI.\n")

    if args.revoke_ci_development:
        for c in ci:
            call("DELETE", f'/certificates/{c["id"]}')
            print(f'Revoked {c["attributes"].get("name", "")} ({c["id"]})')
        print(f"Revoked {len(ci)} certificates.")


if __name__ == "__main__":
    main()
