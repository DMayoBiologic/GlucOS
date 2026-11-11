#!/usr/bin/env python3
"""Ship the iPhone build to external TestFlight testers (anyone with the public link).

Run by .github/workflows/release.yml after the iOS upload, and on a schedule by
.github/workflows/testflight-link.yml (with --link-only) so the public link turns on as soon as
Apple approves the first build, and a build that shipped before the test information was
complete is submitted once it is. Everything is idempotent: it creates or fixes what's missing and
leaves the rest alone.

  1. The "Public" external group, with its public link on (Apple only allows the link once a
     build has passed Beta App Review, so until then this just says so).
  2. Test information testers see (description, privacy policy, feedback email).
  3. Beta App Review details (contact, notes; no demo account needed).
  4. For the new build: wait for processing, add the "What to Test" notes, add it to the group
     and submit it for Beta App Review.

Environment: KEY_P8, KEY_ID, ISSUER (App Store Connect API key, Admin or App Manager role);
APP_VERSION, BUILD_NUMBER (the build just uploaded; not needed with --link-only);
WHATS_NEW_FILE (optional); CONTACT_FIRST_NAME, CONTACT_LAST_NAME, CONTACT_EMAIL, CONTACT_PHONE
(optional, used only where App Store Connect has nothing yet).

Problems Apple can fix later, or that need Declan, are GitHub warnings, not failures: the Mac
release and internal TestFlight have already shipped by the time this runs.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # pyjwt[crypto]

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "au.com.declanmayo.glucos.ios"
GROUP_NAME = "Public"
PRIVACY_URL = "https://gluc-os-seven.vercel.app/privacy/"
MARKETING_URL = "https://github.com/DMayoBiologic/GlucOS"

DESCRIPTION = """GlucOS shows live glucose from a FreeStyle Libre sensor (through LibreLinkUp) on the Lock Screen and in the Dynamic Island, with low and high alerts and a short forecast.

Two ways to use it:
- I wear a sensor: sign in with your LibreLinkUp follower account.
- I'm following someone: no sensor or account needed. Open the GlucOS share link they send you to see their glucose live, on your Lock Screen, with their alerts.

GlucOS is not a medical device. Readings and alerts can be delayed or missed. Always confirm with your sensor app before making treatment decisions."""

REVIEW_NOTES = """GlucOS is a companion viewer for FreeStyle Libre continuous glucose monitors. It is not a medical device and never suggests insulin doses; the app and its test information say so.

To review without a sensor: on the first screen choose "I'm following someone", then tap "See an Example" to see a followed person's live card with example readings. Real follow links come from another GlucOS user (Share button, or GlucOS in the Messages + menu) and open https://gluc-os-seven.vercel.app/share/ with the app installed.

"I wear a sensor" needs a LibreLinkUp follower account linked to a real sensor, so no demo account can be provided. Alerts and Lock Screen updates are sent by the developer's own push service (Supabase) using APNs."""

warnings = []


def warn(msg):
    warnings.append(msg)
    print(f"::warning::{msg}", flush=True)


def summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(text + "\n")
    print(text)


class APIError(Exception):
    def __init__(self, status, body):
        self.status = status
        self.body = body
        try:
            errs = json.loads(body).get("errors", [])
            detail = "; ".join(f"{e.get('title', '')}: {e.get('detail', '')}".strip(": ") for e in errs)
        except Exception:
            detail = body[:500]
        super().__init__(f"HTTP {status}: {detail}")


_token = {"value": None, "at": 0}


def token():
    now = int(time.time())
    if _token["value"] and now - _token["at"] < 600:
        return _token["value"]
    key = os.environ["KEY_P8"]
    t = jwt.encode({"iss": os.environ["ISSUER"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                   key, algorithm="ES256", headers={"kid": os.environ["KEY_ID"], "typ": "JWT"})
    _token.update(value=t, at=now)
    return t


def call(method, path, body=None, params=None):
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")
            if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(5 * 2 ** attempt)
                continue
            raise APIError(e.code, text)
        except urllib.error.URLError:
            if attempt < 3:
                time.sleep(5 * 2 ** attempt)
                continue
            raise


def find_app():
    apps = call("GET", "/apps", params={"filter[bundleId]": BUNDLE_ID, "fields[apps]": "bundleId,name,primaryLocale"})
    for a in apps.get("data", []):
        if a["attributes"]["bundleId"] == BUNDLE_ID:
            return a
    raise SystemExit(f"::error::No App Store Connect app with bundle id {BUNDLE_ID}")


def ensure_group(app_id):
    groups = call("GET", f"/apps/{app_id}/betaGroups", params={"limit": 200})["data"]
    group = next((g for g in groups if g["attributes"]["name"] == GROUP_NAME
                  and not g["attributes"].get("isInternalGroup")), None)
    if group is None:
        print(f"Creating external group {GROUP_NAME!r}")
        group = call("POST", "/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP_NAME, "feedbackEnabled": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})["data"]
    return group


def ensure_public_link(group):
    a = group["attributes"]
    if not a.get("publicLinkEnabled"):
        try:
            group = call("PATCH", f"/betaGroups/{group['id']}", {"data": {
                "type": "betaGroups", "id": group["id"],
                # No limit of our own: TestFlight's is 10,000 testers per app.
                "attributes": {"publicLinkEnabled": True, "publicLinkLimitEnabled": False, "feedbackEnabled": True},
            }})["data"]
        except APIError as e:
            print(f"Public link not on yet ({e}). Apple allows it once a build has passed Beta App Review.")
            return None
    link = group["attributes"].get("publicLink")
    if link:
        summary(f"**Public TestFlight link:** {link}")
    return link


def ensure_test_info(app):
    app_id = app["id"]
    locale = app["attributes"].get("primaryLocale") or "en-US"
    locs = call("GET", f"/apps/{app_id}/betaAppLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == locale), locs[0] if locs else None)
    want = {"description": DESCRIPTION, "privacyPolicyUrl": PRIVACY_URL, "marketingUrl": MARKETING_URL}
    email = os.environ.get("CONTACT_EMAIL", "").strip()
    if loc is None:
        attrs = {"locale": locale, **want}
        if email:
            attrs["feedbackEmail"] = email
        call("POST", "/betaAppLocalizations", {"data": {
            "type": "betaAppLocalizations", "attributes": attrs,
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})
        has_email = bool(email)
    else:
        cur = loc["attributes"]
        changes = {k: v for k, v in want.items() if cur.get(k) != v}
        if email and not cur.get("feedbackEmail"):
            changes["feedbackEmail"] = email
        if changes:
            call("PATCH", f"/betaAppLocalizations/{loc['id']}", {"data": {
                "type": "betaAppLocalizations", "id": loc["id"], "attributes": changes}})
        has_email = bool(cur.get("feedbackEmail") or changes.get("feedbackEmail"))
    if not has_email:
        warn("TestFlight test information has no feedback email. Set the TESTFLIGHT_CONTACT_EMAIL "
             "repository variable (see docs/TestFlight.md), or add it in App Store Connect → TestFlight → Test Information.")
    return has_email


def ensure_review_details(app_id):
    detail = call("GET", f"/apps/{app_id}/betaAppReviewDetail")["data"]
    cur = detail["attributes"]
    changes = {}
    for field, env in (("contactFirstName", "CONTACT_FIRST_NAME"), ("contactLastName", "CONTACT_LAST_NAME"),
                       ("contactEmail", "CONTACT_EMAIL"), ("contactPhone", "CONTACT_PHONE")):
        v = os.environ.get(env, "").strip()
        if v and not cur.get(field):
            changes[field] = v
    if cur.get("notes") != REVIEW_NOTES:
        changes["notes"] = REVIEW_NOTES
    if cur.get("demoAccountRequired") is not False:
        changes["demoAccountRequired"] = False
    if changes:
        call("PATCH", f"/betaAppReviewDetails/{detail['id']}", {"data": {
            "type": "betaAppReviewDetails", "id": detail["id"], "attributes": changes}})
        cur = {**cur, **changes}
    missing = [f for f in ("contactFirstName", "contactLastName", "contactEmail", "contactPhone") if not cur.get(f)]
    if missing:
        warn("Beta App Review needs contact details before external testers get builds (missing: "
             + ", ".join(missing) + "). Set the TESTFLIGHT_CONTACT_* repository variables (see docs/TestFlight.md) "
             "or fill them in App Store Connect → TestFlight → Test Information.")
    return not missing


def wait_for_build(app_id, version, number, minutes=45):
    deadline = time.time() + minutes * 60
    seen = None
    while time.time() < deadline:
        builds = call("GET", "/builds", params={
            "filter[app]": app_id, "filter[version]": number, "filter[preReleaseVersion.version]": version,
            "fields[builds]": "version,processingState,usesNonExemptEncryption,expired", "limit": 5,
        })["data"]
        if builds:
            b = builds[0]
            state = b["attributes"].get("processingState")
            if state != seen:
                print(f"Build {version} ({number}): {state}", flush=True)
                seen = state
            if state == "VALID":
                return b
            if state in ("FAILED", "INVALID"):
                raise SystemExit(f"::error::App Store Connect rejected build {version} ({number}): {state}")
        time.sleep(30)
    raise SystemExit(f"::error::Build {version} ({number}) didn't finish processing in {minutes} minutes")


def set_whats_new(build_id, locale):
    path = os.environ.get("WHATS_NEW_FILE")
    text = open(path).read().strip() if path and os.path.exists(path) else ""
    if not text:
        return
    text = ("What's new:\n" + text)[:3900]
    locs = call("GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == locale), locs[0] if locs else None)
    if loc:
        call("PATCH", f"/betaBuildLocalizations/{loc['id']}", {"data": {
            "type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": text}}})
    else:
        call("POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }})


def ship_build(app, group, ready_for_review):
    version, number = os.environ["APP_VERSION"], os.environ["BUILD_NUMBER"]
    build = wait_for_build(app["id"], version, number)
    bid = build["id"]
    if build["attributes"].get("usesNonExemptEncryption") is None:
        call("PATCH", f"/builds/{bid}", {"data": {"type": "builds", "id": bid,
                                                   "attributes": {"usesNonExemptEncryption": False}}})
    set_whats_new(bid, app["attributes"].get("primaryLocale") or "en-US")
    call("POST", f"/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": bid}]})
    print(f"Added {version} ({number}) to {GROUP_NAME!r}")
    if not ready_for_review:
        warn(f"{version} ({number}) is in the {GROUP_NAME!r} group but wasn't submitted for Beta App Review: "
             "the test information above is incomplete.")
        return
    try:
        call("POST", "/betaAppReviewSubmissions", {"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": bid}}},
        }})
        summary(f"Submitted GlucOS {version} ({number}) for Beta App Review. External testers get it once Apple approves it.")
    except APIError as e:
        if e.status == 409 or "already" in str(e).lower():
            print(f"Already submitted or approved: {e}")
        else:
            warn(f"Couldn't submit {version} ({number}) for Beta App Review: {e}")


def submit_latest_if_needed(app_id, group):
    """The newest build in the group, submitted for review if it never was (test information was
    incomplete when it shipped, and has been filled in since)."""
    builds = call("GET", "/builds", params={
        "filter[app]": app_id, "filter[betaGroups]": group["id"], "sort": "-uploadedDate", "limit": 1,
        "fields[builds]": "version,expired",
    })["data"]
    if not builds or builds[0]["attributes"].get("expired"):
        return
    bid = builds[0]["id"]
    sub = call("GET", f"/builds/{bid}/betaAppReviewSubmission").get("data")
    if sub:
        print(f"Newest build in {GROUP_NAME!r}: review {sub['attributes'].get('betaReviewState')}")
        return
    try:
        call("POST", "/betaAppReviewSubmissions", {"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": bid}}},
        }})
        summary(f"Submitted build {builds[0]['attributes'].get('version')} for Beta App Review.")
    except APIError as e:
        warn(f"Couldn't submit the newest build for Beta App Review: {e}")


def main():
    link_only = "--link-only" in sys.argv
    for k in ("KEY_P8", "KEY_ID", "ISSUER"):
        if not os.environ.get(k):
            print(f"::notice::{k} is not set; skipping external TestFlight.")
            return
    app = find_app()
    group = ensure_group(app["id"])
    has_email = ensure_test_info(app)
    has_contact = ensure_review_details(app["id"])
    if link_only:
        if has_email and has_contact:
            submit_latest_if_needed(app["id"], group)
    else:
        ship_build(app, group, has_email and has_contact)
    link = ensure_public_link(group)
    if not link:
        summary("The public TestFlight link turns on after Apple approves the first build for external testing "
                "(Beta App Review, usually within a day). A scheduled check switches it on then.")


if __name__ == "__main__":
    try:
        main()
    except APIError as e:
        print(f"::error::App Store Connect: {e}")
        sys.exit(1)
