#!/bin/bash
# One-time setup, run on the Mac that holds the Apple Developer account (`make mac-signing-secret`).
# Puts the "Developer ID Application" certificate and its private key into the repo secrets
# MACOS_CERTIFICATE_P12 / MACOS_CERTIFICATE_PASSWORD, which release.yml signs the Mac app with.
# Nothing else in the login keychain leaves the Mac: everything is exported to a temp file, then
# only the Developer ID identity is repacked and uploaded.
#
# No Developer ID certificate yet? Xcode → Settings → Accounts → (your team) → Manage
# Certificates… → + → Developer ID Application, then run this again.
set -euo pipefail
REPO="${REPO:-DMayoBiologic/GlucOS}"

command -v gh >/dev/null || { echo "Installing GitHub CLI…"; brew install gh; }
gh auth status >/dev/null 2>&1 || gh auth login

ID=$(security find-identity -v -p codesigning | grep '"Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
if [ -z "$ID" ]; then
  echo "No Developer ID Application certificate in your keychain."
  echo "Create one: Xcode → Settings → Accounts → your team → Manage Certificates… → + → Developer ID Application."
  echo "Then run 'make mac-signing-secret' again."
  exit 1
fi
echo "Using: $ID"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ALL_PASS=$(openssl rand -hex 16)
echo "macOS will ask to allow exporting your signing keys. Enter your login password and click Allow."
security export -t identities -f pkcs12 -P "$ALL_PASS" -o "$TMP/all.p12"

# LibreSSL (macOS) and OpenSSL 3 both read these; -legacy only exists on OpenSSL 3.
LEGACY=""; openssl pkcs12 -help 2>&1 | grep -q -- -legacy && LEGACY="-legacy"
openssl pkcs12 $LEGACY -in "$TMP/all.p12" -passin "pass:$ALL_PASS" -nokeys -clcerts -out "$TMP/certs.pem" 2>/dev/null
openssl pkcs12 $LEGACY -in "$TMP/all.p12" -passin "pass:$ALL_PASS" -nocerts -nodes -out "$TMP/keys.pem" 2>/dev/null

# Split into one file per PEM block, keeping the bag attributes (localKeyID pairs a cert with its key).
awk -v d="$TMP" '/^Bag Attributes/{n++; f=sprintf("%s/cert%03d.pem", d, n)} f{print > f}' "$TMP/certs.pem"
awk -v d="$TMP" '/^Bag Attributes/{n++; f=sprintf("%s/key%03d.pem", d, n)} f{print > f}' "$TMP/keys.pem"

CERT=""
for c in "$TMP"/cert*.pem; do
  SUBJ=$(openssl x509 -in "$c" -noout -subject 2>/dev/null || true)
  case "$SUBJ" in *"${ID#Developer ID Application: }"*) case "$SUBJ" in *"Developer ID Application"*) CERT="$c" ;; esac ;; esac
  [ -n "$CERT" ] && break
done
[ -n "$CERT" ] || { echo "Couldn't find the Developer ID certificate in the export"; exit 1; }
CERT_PUB=$(openssl x509 -in "$CERT" -noout -pubkey | openssl md5)
KEY=""
for k in "$TMP"/key*.pem; do
  [ "$(openssl pkey -in "$k" -pubout 2>/dev/null | openssl md5)" = "$CERT_PUB" ] && { KEY="$k"; break; }
done
[ -n "$KEY" ] || { echo "Couldn't find the private key for $ID (was it created on another Mac?)"; exit 1; }

PASS=$(openssl rand -hex 24)
# -legacy keeps the .p12 readable by the macOS `security import` on the build runners.
openssl pkcs12 $LEGACY -export -in "$CERT" -inkey "$KEY" -name "$ID" -passout "pass:$PASS" -out "$TMP/devid.p12"
base64 < "$TMP/devid.p12" | tr -d '\n' | gh secret set MACOS_CERTIFICATE_P12 -R "$REPO"
printf '%s' "$PASS" | gh secret set MACOS_CERTIFICATE_PASSWORD -R "$REPO"
echo "Done: $REPO now signs Mac releases as $ID."
