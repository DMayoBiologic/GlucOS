# Mac signing and the Keychain prompt

## The problem

Until this change every Mac release was ad-hoc signed. An ad-hoc signature is only a hash of the
build, so the login keychain saw each Sparkle update as a different app and asked for the
Keychain password before GlucOS could read the LibreLinkUp password or the logbook sync session.
"Always Allow" only ever trusted that one build.

## The fix

- **Developer ID signing, set up by CI.** `scripts/mac_identity.sh` gives every release the same
  Developer ID Application identity. The first run with no identity makes a key on the runner,
  asks Apple for a certificate through the App Store Connect API key
  (`scripts/asc_developer_id.py`), and keeps the identity encrypted (with a key derived from
  `SPARKLE_PRIVATE_KEY`) as `developer-id.p12.enc` on the `mac-signing` prerelease. Later runs
  reuse it. `MACOS_CERTIFICATE_P12`/`PASSWORD` secrets override it if ever set.
  Nobody has to do anything by hand.
- **Everything signed.** `scripts/seal_mac_app.sh` re-signs Sparkle's helpers, the widget and
  the app with the hardened runtime and a timestamp, then checks the Team ID. The release
  notarizes and staples (a notary failure warns but doesn't stop the release, since Sparkle
  updates aren't quarantined).
- **Items re-saved once.** `Sources/App/Keychain.swift`: a Developer ID build keeps its items
  under `au.com.declanmayo.glucos.signed`, created by itself, so every later build of the same
  team reads them without asking. The first read copies each old item across (that read may
  ask one last time). Ad-hoc local builds and the iPhone keep the old service.
- **No going back.** Once the sealed identity exists, a run that can't open it fails instead of
  shipping an ad-hoc build, which would bring the prompt back.
- `.github/workflows/mac-signing.yml` signs and notarizes on pull requests that touch any of this.

## What you see

The first update to a Developer ID build may ask once per saved item (password, sync session).
Choose **Always Allow**. Updates after that don't ask.

Deleting the `mac-signing` release makes CI create a new identity on the next release. That
still works without prompts: the keychain trusts the Team ID, not the certificate.
