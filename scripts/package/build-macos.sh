#!/usr/bin/env bash
# Builds a .pkg installer from the release binary.
#
# Usage:
#   ./build-macos.sh <version> <arch> <path-to-qbit-binary> <output-dir>
#
# Example:
#   ./build-macos.sh 1.0.0 arm64 target/release/qbit dist
#
# Optional signing/notarization (used automatically if all required
# env vars are set; otherwise an unsigned artifact is produced and
# clearly logged as such):
#   MACOS_SIGNING_IDENTITY   - "Developer ID Application: Your Name (TEAMID)"
#   MACOS_INSTALLER_IDENTITY - "Developer ID Installer: Your Name (TEAMID)"
#   MACOS_NOTARY_PROFILE     - a notarytool keychain profile name (via `xcrun notarytool store-credentials`)

set -euo pipefail

VERSION="${1:?version required, e.g. 1.0.0}"
ARCH="${2:?arch required, e.g. arm64 or x86_64}"
BINARY_PATH="${3:?path to built qbit binary required}"
OUT_DIR="${4:-dist}"

# --- Requirement 4.5: architecture allowlist ---
case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "error: invalid architecture '$ARCH'. Allowed: arm64, x86_64" >&2
    exit 1
    ;;
esac

if [ ! -f "$BINARY_PATH" ]; then
  echo "error: binary not found at $BINARY_PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MACOS_PKG_DIR="$REPO_ROOT/packaging/macos"
IDENTIFIER="com.qbit-click.qbit-cli"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

PAYLOAD_DIR="$STAGE_DIR/payload"
mkdir -p "$PAYLOAD_DIR/usr/local/bin"

# --- Requirement 4.3: binary only ever installed at /usr/local/bin/qbit ---
cp "$BINARY_PATH" "$PAYLOAD_DIR/usr/local/bin/qbit"
chmod 755 "$PAYLOAD_DIR/usr/local/bin/qbit"

# Optional: sign the binary before packaging, if a signing identity is configured
SIGNED="false"
if [ -n "${MACOS_SIGNING_IDENTITY:-}" ]; then
  echo "Signing binary with identity: $MACOS_SIGNING_IDENTITY"
  codesign --force --options runtime --sign "$MACOS_SIGNING_IDENTITY" "$PAYLOAD_DIR/usr/local/bin/qbit"
  SIGNED="true"
else
  echo "NOTICE: MACOS_SIGNING_IDENTITY not set — building an UNSIGNED binary."
fi

# Render distribution.xml with the real version
sed "s/__VERSION__/$VERSION/" "$MACOS_PKG_DIR/distribution.xml" > "$STAGE_DIR/distribution.xml"

# --- Requirement 4.1: after render, no __VERSION__ placeholder may remain ---
if grep -q "__VERSION__" "$STAGE_DIR/distribution.xml"; then
  echo "error: __VERSION__ placeholder was not substituted in distribution.xml" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# --- Requirement 4.2: component package version must match distribution version ---
pkgbuild \
  --root "$PAYLOAD_DIR" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$STAGE_DIR/component.pkg"

# --- Requirement 4.4: deterministic output filename ---
PKG_NAME="qbit-cli-${VERSION}-macos-${ARCH}.pkg"
OUT_FILE="$OUT_DIR/$PKG_NAME"

PRODUCTBUILD_ARGS=(
  --distribution "$STAGE_DIR/distribution.xml"
  --package-path "$STAGE_DIR"
)

INSTALLER_SIGNED="false"
if [ -n "${MACOS_INSTALLER_IDENTITY:-}" ]; then
  echo "Signing installer with identity: $MACOS_INSTALLER_IDENTITY"
  PRODUCTBUILD_ARGS+=(--sign "$MACOS_INSTALLER_IDENTITY")
  INSTALLER_SIGNED="true"
else
  echo "NOTICE: MACOS_INSTALLER_IDENTITY not set — building an UNSIGNED installer package."
fi

productbuild "${PRODUCTBUILD_ARGS[@]}" "$OUT_FILE"

echo "Built: $OUT_FILE"

# --- Requirement 4.8/4.9: notarize + staple only if fully signed and a
# notary profile is configured. Otherwise, clearly log unsigned status
# rather than silently skipping or mislabeling the artifact. ---
if [ "$SIGNED" = "true" ] && [ "$INSTALLER_SIGNED" = "true" ] && [ -n "${MACOS_NOTARY_PROFILE:-}" ]; then
  echo "Submitting for notarization using profile: $MACOS_NOTARY_PROFILE"
  xcrun notarytool submit "$OUT_FILE" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT_FILE"
  echo "RELEASE_ARTIFACT_STATUS: signed+notarized"
else
  echo "RELEASE_ARTIFACT_STATUS: unsigned (this build was not signed and/or not notarized)"
fi

# --- Requirement 4.6: real validation, no silent '|| true' ---
# 1. pkgutil must be able to open/expand the package.
# 2. The payload must contain usr/local/bin/qbit.
# 3. Missing expected payload must fail the build.
EXPAND_DIR="$STAGE_DIR/expanded"
if ! pkgutil --expand-full "$OUT_FILE" "$EXPAND_DIR" 2>/dev/null; then
  # --expand-full is newer; fall back to --expand + manual payload check
  pkgutil --expand "$OUT_FILE" "$EXPAND_DIR"
fi

PAYLOAD_FILES="$(pkgutil --payload-files "$OUT_FILE" 2>/dev/null || true)"
if ! echo "$PAYLOAD_FILES" | grep -qE '(^|/)usr/local/bin/qbit$'; then
  echo "error: expected payload usr/local/bin/qbit not found in built package" >&2
  echo "Actual payload contents:" >&2
  echo "$PAYLOAD_FILES" >&2
  exit 1
fi

echo "Validated payload contains: usr/local/bin/qbit"
