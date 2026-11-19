#!/usr/bin/env python3
"""Asks Apple for a Developer ID Application certificate for a CSR, through the App Store Connect API.

Used once by scripts/mac_identity.sh, the first time a Mac release has no Developer ID identity
to sign with. The private key never leaves the runner; Apple only sees the CSR. Writes the issued
certificate (DER) to --out.

Exit codes: 0 issued, 3 Apple refused (the caller falls back to ad-hoc signing and says why).

Needs KEY_ID, ISSUER, KEY_P8 (the App Store Connect API key). Uses the helpers in
testflight_external.py.
"""
import argparse
import base64
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from testflight_external import APIError, call  # noqa: E402

# G2 is the current Developer ID intermediate; the older type is a fallback for accounts the
# API still offers only that one to.
TYPES = ["DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--csr", required=True, help="PEM certificate signing request")
    p.add_argument("--out", required=True, help="where to write the issued certificate (DER)")
    args = p.parse_args()

    csr = open(args.csr).read()
    errors = []
    for kind in TYPES:
        try:
            res = call("POST", "/certificates", body={"data": {
                "type": "certificates",
                "attributes": {"certificateType": kind, "csrContent": csr},
            }})
        except APIError as e:
            errors.append(f"{kind}: {e}")
            continue
        a = res["data"]["attributes"]
        with open(args.out, "wb") as f:
            f.write(base64.b64decode(a["certificateContent"]))
        print(f"Issued {kind} certificate {res['data']['id']} ({a.get('name', '')}), "
              f"expires {a.get('expirationDate', '?')[:10]}")
        return 0
    for e in errors:
        print(f"::warning::Apple refused a Developer ID certificate: {e}")
    return 3


if __name__ == "__main__":
    sys.exit(main())
