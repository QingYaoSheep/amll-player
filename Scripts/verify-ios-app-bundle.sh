#!/bin/bash
set -euo pipefail

APP_BUNDLE="${1:?usage: verify-ios-app-bundle.sh /path/to/AMLLPlayer.app}"
INFO_PLIST="$APP_BUNDLE/Info.plist"

fail() {
    echo "$1" >&2
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::error::$1"
    fi
    exit 1
}

if [[ ! -f "$INFO_PLIST" ]]; then
    fail "Missing application Info.plist: $INFO_PLIST"
fi

APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
BUNDLE_ICON_FILES="$(find "$APP_BUNDLE" -maxdepth 1 \( -name '*Icon*' -o -name '*.car' -o -name '*.icon' \) -exec basename {} \; 2>/dev/null | tr '\n' ' ' || true)"
APP_ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$APP_ICON_NAME" != "AppIcon" ]]; then
    fail "Unexpected CFBundleIconName='$APP_ICON_NAME'; bundle icon files: $BUNDLE_ICON_FILES"
fi
if [[ -e "$APP_BUNDLE/AppIcon.icon" ]]; then
    fail "Raw AppIcon.icon copied verbatim into app bundle; bundle icon files: $BUNDLE_ICON_FILES"
fi
if [[ ! -s "$APP_BUNDLE/Assets.car" ]]; then
    fail "Missing compiled Assets.car; bundle icon files: $BUNDLE_ICON_FILES"
fi
ASSETUTIL_INFO="$(xcrun assetutil --info "$APP_BUNDLE/Assets.car" 2>&1)" || fail "xcrun assetutil failed: $(printf '%s' "$ASSETUTIL_INFO" | tr '\n' ' ' | cut -c1-400)"
APP_ICON_COUNT="$(printf '%s\n' "$ASSETUTIL_INFO" | grep -Fc 'AppIcon' || true)"
ICON_STACK_COUNT="$(printf '%s\n' "$ASSETUTIL_INFO" | grep -Fc 'IconImageStack' || true)"
if [[ "$APP_ICON_COUNT" -eq 0 || "$ICON_STACK_COUNT" -eq 0 ]]; then
    ASSET_SUMMARY="$(printf '%s\n' "$ASSETUTIL_INFO" | grep -E '"AssetType"|"Name"' | head -n 20 | tr '\n' ';' | cut -c1-500 || true)"
    fail "Assets.car missing compiled Icon Composer stack (AppIcon=$APP_ICON_COUNT, IconImageStack=$ICON_STACK_COUNT); bundle icon files: $BUNDLE_ICON_FILES; assetutil sample: $ASSET_SUMMARY"
fi
echo "Compiled Icon Composer AppIcon verified in Assets.car (AppIcon=$APP_ICON_COUNT, IconImageStack=$ICON_STACK_COUNT, bundle files: $BUNDLE_ICON_FILES)"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice::Compiled Icon Composer AppIcon verified in Assets.car (AppIcon=$APP_ICON_COUNT, IconImageStack=$ICON_STACK_COUNT, bundle files: $BUNDLE_ICON_FILES)"
fi
for REQUIRED_RESOURCE in default.metallib amll-mesh-presets.json; do
    if [[ ! -s "$APP_BUNDLE/$REQUIRED_RESOURCE" ]]; then
        echo "Missing visual rendering resource: $REQUIRED_RESOURCE" >&2
        exit 1
    fi
done
for DEBUG_FIXTURE in amll-shared-lyrics.json amll-shared-replay.json; do
    if [[ -e "$APP_BUNDLE/$DEBUG_FIXTURE" ]]; then
        echo "Release bundle must not contain debug fixture: $DEBUG_FIXTURE" >&2
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
WIDGET="$APP_BUNDLE/PlugIns/LockScreenLyricsWidget.appex"
WIDGET_PLIST="$WIDGET/Info.plist"
if [[ ! -s "$WIDGET_PLIST" || "$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsLiveActivities' "$INFO_PLIST")" != "true" ]]; then
    echo "Missing embedded Lock Screen Lyrics widget or Live Activities opt-in" >&2
    exit 1
fi
APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
WIDGET_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WIDGET_PLIST")"
WIDGET_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$WIDGET_PLIST")"
WIDGET_POINT="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$WIDGET_PLIST")"
if [[ "$WIDGET_IDENTIFIER" != "$APP_IDENTIFIER.lockscreenlyrics" || "$WIDGET_POINT" != com.apple.widgetkit-extension || ! -s "$WIDGET/$WIDGET_EXECUTABLE" ]]; then
    echo "Invalid Lock Screen Lyrics widget bundle" >&2
    exit 1
fi

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

echo "Verified orientation and ProMotion, Spotify callback and framework, widget extension, offline dictionary, and runtime search path"
