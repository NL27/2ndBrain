#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity in the login keychain so
# macOS Privacy (TCC) remembers granted permissions (Screen Recording,
# Microphone, …) across rebuilds — instead of re-prompting every time.
#
# This needs ONE interactive approval:
#   • a dialog to trust the new certificate (enter your login password), and
#   • the first build will ask to use the key — click "Always Allow".
# After that, all rebuilds sign cleanly and permissions persist.
set -euo pipefail

IDENTITY_NAME="${1:-2nd Brain Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

trusted() { security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; }
exists()  { security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; }

if trusted; then
  echo "==> '$IDENTITY_NAME' already exists and is trusted. Nothing to do."
  exit 0
fi

if ! exists; then
  echo "==> Generating self-signed code-signing certificate '$IDENTITY_NAME'…"
  cat > "$TMP/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $IDENTITY_NAME
[ v3 ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1

  # Import cert + key separately (PKCS#12 from LibreSSL fails macOS import).
  security import "$TMP/cert.pem" -k "$KEYCHAIN" -A -T /usr/bin/codesign >/dev/null 2>&1 || true
  security import "$TMP/key.pem"  -k "$KEYCHAIN" -A -T /usr/bin/codesign >/dev/null 2>&1 || true
else
  echo "==> Certificate already present; adding trust…"
  security find-certificate -c "$IDENTITY_NAME" -p "$KEYCHAIN" > "$TMP/cert.pem" 2>/dev/null || true
fi

echo "==> Trusting the certificate for code signing (you may be asked for your login password)…"
if [[ -f "$TMP/cert.pem" ]]; then
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 || \
    echo "    (Trust step skipped/cancelled — you can re-run this script.)"
fi

if trusted; then
  echo "==> Done. '$IDENTITY_NAME' is ready. Rebuild with scripts/build.sh."
else
  echo "!! Identity is not yet trusted; builds will use ad-hoc signing for now." >&2
  exit 1
fi
