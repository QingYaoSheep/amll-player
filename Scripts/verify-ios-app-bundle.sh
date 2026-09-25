#!/bin/bash
set -euo pipefail

APP_BUNDLE="${1:?usage: verify-ios-app-bundle.sh /path/to/AMLLPlayer.app}"
INFO_PLIST="$APP_BUNDLE/Info.plist"

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Missing application Info.plist: $INFO_PLIST" >&2
    exit 1
fi

APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
for REQUIRED_RESOURCE in default.metallib amll-mesh-presets.json; do
    if [[ ! -s "$APP_BUNDLE/$REQUIRED_RESOURCE" ]]; then
        echo "Missing visual rendering resource: $REQUIRED_RESOURCE" >&2
        exit 1
    fi
done
ROMANIZATION_ROOT="$APP_BUNDLE/Romanization"
if [[ ! -d "$ROMANIZATION_ROOT" ]]; then
    ROMANIZATION_ROOT="$APP_BUNDLE"
fi
for DICTIONARY_PART in base check tid tid_pos tid_map cc unk unk_pos unk_map unk_char unk_compat unk_invoke; do
    if [[ ! -s "$ROMANIZATION_ROOT/roman-$DICTIONARY_PART.deflate" ]]; then
        echo "Missing offline romanization dictionary part: $DICTIONARY_PART" >&2
        exit 1
    fi
done
for ROMANIZATION_RESOURCE in roman-kana-map.json romanization-resources.json; do
    if [[ ! -s "$ROMANIZATION_ROOT/$ROMANIZATION_RESOURCE" ]]; then
        echo "Missing offline romanization resource: $ROMANIZATION_RESOURCE" >&2
        exit 1
    fi
done
ROMANIZATION_KIB="$(du -ck "$ROMANIZATION_ROOT"/roman-*.deflate \
    "$ROMANIZATION_ROOT/roman-kana-map.json" "$ROMANIZATION_ROOT/romanization-resources.json" | tail -1 | cut -f1)"
echo "Offline romanization resources: $ROMANIZATION_KIB KiB in bundle"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CADisableMinimumFrameDurationOnPhone' "$INFO_PLIST")" != "true" ]]; then
    echo "Application is missing the ProMotion timing opt-in" >&2
    exit 1
fi
for ORIENTATION_KEY in UISupportedInterfaceOrientations 'UISupportedInterfaceOrientations~ipad'; do
    ORIENTATIONS="$(/usr/libexec/PlistBuddy -c "Print :$ORIENTATION_KEY" "$INFO_PLIST")"
    for REQUIRED_ORIENTATION in UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight; do
        if [[ "$ORIENTATIONS" != *"$REQUIRED_ORIENTATION"* ]]; then
            echo "Missing $REQUIRED_ORIENTATION in $ORIENTATION_KEY" >&2
            exit 1
        fi
    done
done
SPOTIFY_REDIRECT_URI="$(/usr/libexec/PlistBuddy -c 'Print :SpotifyRedirectURI' "$INFO_PLIST")"
if [[ "$SPOTIFY_REDIRECT_URI" != "amllplayer://spotify-callback" ]]; then
    echo "Invalid built Spotify redirect URI: $SPOTIFY_REDIRECT_URI" >&2
    exit 1
fi

SPOTIFY_CALLBACK_SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$INFO_PLIST")"
if [[ "$SPOTIFY_CALLBACK_SCHEME" != "amllplayer" ]]; then
    echo "Application does not register the Spotify callback URL scheme" >&2
    exit 1
fi

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

echo "Verified ProMotion/orientations, Spotify callback, embedded framework, offline dictionary, and runtime search path"
