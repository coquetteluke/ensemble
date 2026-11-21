#!/bin/bash
# Makes the certificate that release builds are signed with. Run it once, on the Mac that makes the releases.
# Usage: scripts/installer/make-signing-identity.sh
#
# Why: with no paid Apple Developer account, the app can be signed ad hoc or with a certificate made here.
# Ad hoc gives every build a different designated requirement. A certificate made once and reused keeps it the
# same from build to build ("this identifier, signed by this certificate").
#
# What it does NOT do, measured on macOS 27.2 in the real login keychain:
#   - It does not stop the keychain password prompt after an update. The login keychain gives each item a
#     "partition list", and for code without an Apple team id the entry is the hash of that exact build. A later
#     build signed with this same certificate is refused and macOS asks again. Only a certificate issued by Apple
#     (a team id) carries over. A keychain file made with `security create-keychain` has no partition lists, so a
#     test there passes and proves nothing.
#   - It does not remove the "Not Opened" warning: Apple still has not checked the app.
#
# Where: ~/.ensemble-signing (or $ENSEMBLE_SIGNING_DIR), outside the repository: identity.p12, its passphrase and
# the public certificate. Keep the folder private and back it up.
#   Lose it: the next release gets a new designated requirement.
#   Leak it: someone else could sign an app with Ensemble's designated requirement.
# The certificate holds the name "Ensemble Release" and nothing about the person who made it.
set -euo pipefail
folder="${ENSEMBLE_SIGNING_DIR:-$HOME/.ensemble-signing}"
if [ -e "$folder/identity.p12" ]; then
  echo "error: $folder/identity.p12 already exists. It is not replaced: a new certificate is a new identity." >&2
  exit 1
fi
umask 077
mkdir -p "$folder"
work="$(mktemp -d /private/tmp/ensemble-signing.XXXXXX)"
trap 'rm -rf "$work"' EXIT
cat >"$work/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = name
x509_extensions = extensions
prompt = no
[name]
CN = Ensemble Release
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
passphrase="$(openssl rand -hex 24)"
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$work/certificate.cnf" \
  -keyout "$work/key.pem" -out "$work/certificate.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/certificate.pem" -name "Ensemble Release" \
  -out "$folder/identity.p12" -passout "pass:$passphrase" 2>/dev/null
printf '%s\n' "$passphrase" >"$folder/passphrase"
cp "$work/certificate.pem" "$folder/certificate.pem"
chmod 600 "$folder/identity.p12" "$folder/passphrase" "$folder/certificate.pem"
echo "Made the release signing certificate in $folder"
echo "SHA-256: $(openssl x509 -in "$folder/certificate.pem" -noout -fingerprint -sha256 | sed 's/.*=//')"
echo "Valid until: $(openssl x509 -in "$folder/certificate.pem" -noout -enddate | sed 's/.*=//')"
echo "Back this folder up somewhere private. scripts/make-installer.sh uses it from now on."
