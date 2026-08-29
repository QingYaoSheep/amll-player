#!/bin/bash
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_ROOT="$REPOSITORY_ROOT/.tools/xcodegen/$XCODEGEN_VERSION"
BINARY="$INSTALL_ROOT/bin/xcodegen"

if [[ -x "$BINARY" ]]; then
    "$BINARY" --version
    exit 0
fi

ARCHIVE="$(mktemp -t xcodegen.XXXXXX).zip"
EXTRACTED="$(mktemp -d -t xcodegen.XXXXXX)"
trap 'rm -f "$ARCHIVE"; rm -rf "$EXTRACTED"' EXIT

curl --fail --location --retry 3 \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
    --output "$ARCHIVE"
ditto -x -k "$ARCHIVE" "$EXTRACTED"

mkdir -p "$INSTALL_ROOT/bin"
if [[ -x "$EXTRACTED/bin/xcodegen" ]]; then
    cp "$EXTRACTED/bin/xcodegen" "$BINARY"
elif [[ -x "$EXTRACTED/xcodegen/bin/xcodegen" ]]; then
    cp "$EXTRACTED/xcodegen/bin/xcodegen" "$BINARY"
else
    echo "Unable to locate xcodegen in release archive" >&2
    exit 1
fi

chmod +x "$BINARY"
"$BINARY" --version
