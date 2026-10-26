#!/usr/bin/env bash
# Builds a .deb package from the release binary.
#
# Usage:
#   QBIT_MAINTAINER="Real Name <real@email.example>" \
#     ./build-linux-deb.sh <version> <arch> <path-to-qbit-binary> <output-dir>
#
# Example:
#   QBIT_MAINTAINER="Qbit Team <maintainers@qbit-click.dev>" \
#     ./build-linux-deb.sh 1.0.0 amd64 target/release/qbit dist

set -euo pipefail

VERSION="${1:?version required, e.g. 1.0.0}"
ARCH="${2:?arch required, e.g. amd64}"
BINARY_PATH="${3:?path to built qbit binary required}"
OUT_DIR="${4:-dist}"

# --- Requirement 5.3: architecture allowlist ---
case "$ARCH" in
  amd64|arm64) ;;
  *)
    echo "error: invalid architecture '$ARCH'. Allowed: amd64, arm64" >&2
    exit 1
    ;;
esac

# --- Requirement 5.4: Debian version format validation ---
# Debian policy version format: [epoch:]upstream_version[-debian_revision]
# We keep it simple and strict here: require a plain numeric X.Y.Z,
# rejecting suffixes like "-ci" that are not meaningful Debian versions
# for a real release (a real -N revision suffix can be added later if
# genuinely needed for repackaging without a new upstream version).
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid version '$VERSION'. Expected strict X.Y.Z (no suffixes)." >&2
  exit 1
fi

if [ ! -f "$BINARY_PATH" ]; then
  echo "error: binary not found at $BINARY_PATH" >&2
  exit 1
fi

# Maintainer defaults to a generic project address if not overridden.
# Set QBIT_MAINTAINER to customize (e.g. in CI), but it's not required.
QBIT_MAINTAINER="${QBIT_MAINTAINER:-Qbit CLI Maintainers <qbit-cli@qbit-click.dev>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTROL_TEMPLATE="$REPO_ROOT/packaging/linux/debian/control.template"

if [ ! -f "$CONTROL_TEMPLATE" ]; then
  echo "error: control template not found at $CONTROL_TEMPLATE" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

# --- Requirement 5.1: package root / artifact use qbit-cli naming ---
PKG_NAME="qbit-cli_${VERSION}_${ARCH}"
PKG_ROOT="$STAGE_DIR/$PKG_NAME"

mkdir -p "$PKG_ROOT/usr/bin"
mkdir -p "$PKG_ROOT/DEBIAN"

# --- Requirement 5.2: binary installed at /usr/bin/qbit ---
cp "$BINARY_PATH" "$PKG_ROOT/usr/bin/qbit"
chmod 755 "$PKG_ROOT/usr/bin/qbit"

# Render control file with real version/arch/maintainer.
# Strip CR characters and blank lines defensively — dpkg-deb's parser
# is strict and a blank line inside/after a multi-line field is an error.
sed \
  -e "s/__VERSION__/$VERSION/" \
  -e "s/__ARCH__/$ARCH/" \
  -e "s/__MAINTAINER__/$QBIT_MAINTAINER/" \
  "$CONTROL_TEMPLATE" \
  | tr -d '\r' \
  | sed '/^[[:space:]]*$/d' > "$PKG_ROOT/DEBIAN/control"

# --- Requirement 5.5: no placeholder may survive rendering ---
if grep -qE "__VERSION__|__ARCH__|__MAINTAINER__" "$PKG_ROOT/DEBIAN/control"; then
  echo "error: unsubstituted placeholder remains in rendered control file:" >&2
  cat "$PKG_ROOT/DEBIAN/control" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/${PKG_NAME}.deb"

dpkg-deb --build --root-owner-group "$PKG_ROOT" "$OUT_FILE"

echo "Built: $OUT_FILE"

# --- Requirement 5.6: metadata verified with dpkg-deb --info ---
echo "--- dpkg-deb info ---"
INFO_OUTPUT="$(dpkg-deb --info "$OUT_FILE")"
echo "$INFO_OUTPUT"

if ! echo "$INFO_OUTPUT" | grep -q "^ Package: qbit-cli$"; then
  echo "error: built package does not report Package: qbit-cli" >&2
  exit 1
fi

# --- Requirement 5.7 / 5.8: payload verified with dpkg-deb --contents;
# missing /usr/bin/qbit must fail the build ---
echo "--- dpkg-deb contents ---"
CONTENTS_OUTPUT="$(dpkg-deb --contents "$OUT_FILE")"
echo "$CONTENTS_OUTPUT"

if ! echo "$CONTENTS_OUTPUT" | grep -qE '\./usr/bin/qbit$'; then
  echo "error: expected payload ./usr/bin/qbit not found in built package" >&2
  exit 1
fi

echo "Validated: Package=qbit-cli, payload contains ./usr/bin/qbit"
