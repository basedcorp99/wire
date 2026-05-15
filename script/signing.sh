#!/usr/bin/env bash
set -euo pipefail

# Stable local signing for development builds.
# TCC/Accessibility keys trust to the app's code requirement. Unsigned/ad-hoc
# rebuilds change that requirement, so paste permission appears enabled in
# Settings but AXIsProcessTrusted() returns false.

WIRE_CODESIGN_IDENTITY="${WIRE_CODESIGN_IDENTITY:-wire Local Code Signing}"
WIRE_KEYCHAIN="${WIRE_KEYCHAIN:-$HOME/Library/Keychains/wire-build.keychain-db}"
WIRE_KEYCHAIN_PASSWORD="${WIRE_KEYCHAIN_PASSWORD:-wire}"

ensure_keychain() {
  if [[ ! -f "$WIRE_KEYCHAIN" ]]; then
    /usr/bin/security create-keychain -p "$WIRE_KEYCHAIN_PASSWORD" "$WIRE_KEYCHAIN" >/dev/null
  fi
  /usr/bin/security unlock-keychain -p "$WIRE_KEYCHAIN_PASSWORD" "$WIRE_KEYCHAIN" >/dev/null
  /usr/bin/security set-keychain-settings -lut 21600 "$WIRE_KEYCHAIN" >/dev/null

  local current
  current="$(/usr/bin/security list-keychains -d user | /usr/bin/sed 's/[ " ]//g')"
  if ! /usr/bin/grep -Fxq "$WIRE_KEYCHAIN" <<<"$current"; then
    /usr/bin/security list-keychains -d user -s "$WIRE_KEYCHAIN" $current >/dev/null
  fi
}

has_codesign_identity() {
  ensure_keychain
  /usr/bin/security find-identity -v -p codesigning "$WIRE_KEYCHAIN" 2>/dev/null | /usr/bin/grep -Fq "\"$WIRE_CODESIGN_IDENTITY\""
}

create_codesign_identity() {
  if has_codesign_identity; then
    return 0
  fi

  local tmp
  tmp="$(/usr/bin/mktemp -d)"

  cat > "$tmp/openssl.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = $WIRE_CODESIGN_IDENTITY
O = wire

[v3_req]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

  /usr/bin/openssl req \
    -new \
    -x509 \
    -nodes \
    -days 3650 \
    -config "$tmp/openssl.cnf" \
    -keyout "$tmp/wire-codesign.key" \
    -out "$tmp/wire-codesign.crt" >/dev/null 2>&1

  /usr/bin/openssl pkcs12 \
    -export \
    -inkey "$tmp/wire-codesign.key" \
    -in "$tmp/wire-codesign.crt" \
    -name "$WIRE_CODESIGN_IDENTITY" \
    -out "$tmp/wire-codesign.p12" \
    -passout pass:"$WIRE_KEYCHAIN_PASSWORD" >/dev/null 2>&1

  ensure_keychain
  /usr/bin/security import "$tmp/wire-codesign.p12" \
    -k "$WIRE_KEYCHAIN" \
    -P "$WIRE_KEYCHAIN_PASSWORD" \
    -A >/dev/null

  /usr/bin/security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$WIRE_KEYCHAIN" \
    "$tmp/wire-codesign.crt" >/dev/null 2>&1 || true

  /usr/bin/security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$WIRE_KEYCHAIN_PASSWORD" \
    "$WIRE_KEYCHAIN" >/dev/null 2>&1 || true

  rm -rf "$tmp"
  has_codesign_identity
}

sign_app() {
  local app="$1"
  create_codesign_identity
  /usr/bin/security unlock-keychain -p "$WIRE_KEYCHAIN_PASSWORD" "$WIRE_KEYCHAIN" >/dev/null
  /usr/bin/codesign \
    --force \
    --deep \
    --keychain "$WIRE_KEYCHAIN" \
    --sign "$WIRE_CODESIGN_IDENTITY" \
    "$app" >/dev/null
}
