#!/usr/bin/env bash
# Creates a self-signed code-signing certificate "OpenUsage Local Signing" in the login keychain, once.
# Signing every rebuild with it keeps the app's code identity stable, so the Keychain "Always Allow"
# answers for OpenUsage's saved accounts survive rebuilds. It never leaves this Mac.
set -euo pipefail
NAME="OpenUsage Local Signing"
if /usr/bin/security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "==> \"$NAME\" already exists"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/req.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:openusage >/dev/null 2>&1
/usr/bin/security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P openusage -T /usr/bin/codesign >/dev/null
echo "==> created \"$NAME\" in the login keychain"
