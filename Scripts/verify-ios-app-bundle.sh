#!/bin/bash
set -euo pipefail

APP_BUNDLE="${1:?usage: verify-ios-app-bundle.sh /path/to/AMLLPlayer.app}"
INFO_PLIST="$APP_BUNDLE/Info.plist"

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Missing application Info.plist: $INFO_PLIST" >&2
    exit 1
fi

APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
APP_EXECUTABLE="$APP_BUNDLE/$APP_EXECUTABLE_NAME"
SPOTIFY_EXECUTABLE="$APP_BUNDLE/Frameworks/SpotifyiOS.framework/SpotifyiOS"

if [[ ! -f "$APP_EXECUTABLE" ]]; then
    echo "Missing application executable: $APP_EXECUTABLE" >&2
    exit 1
fi

if [[ ! -f "$SPOTIFY_EXECUTABLE" ]]; then
    echo "SpotifyiOS.framework was not embedded in the application bundle" >&2
    exit 1
fi

if ! otool -L "$APP_EXECUTABLE" | grep -Fq '@rpath/SpotifyiOS.framework/SpotifyiOS'; then
    echo "Application executable is not linked to SpotifyiOS.framework" >&2
    exit 1
fi

if ! otool -l "$APP_EXECUTABLE" | grep -Fq '@executable_path/Frameworks'; then
    echo "Application executable is missing @executable_path/Frameworks LC_RPATH" >&2
    exit 1
fi

echo "Verified embedded Spotify framework and application runtime search path"
