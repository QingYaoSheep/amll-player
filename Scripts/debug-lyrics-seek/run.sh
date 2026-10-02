#!/bin/bash
set -eu
mkdir -p build/seek-loop
node - <<'NODE'
const fs = require('node:fs');
const text = fs.readFileSync('AMLLPlayer/Domain/Lyrics.swift','utf8');
fs.writeFileSync('build/seek-loop/Models.swift', text.slice(0,text.indexOf('struct LyricsAsset:')));
NODE
cat > build/seek-loop/Stubs.swift <<'SWIFT'
import Foundation
enum MusicServiceID: String, Sendable { case spotify, appleMusic, netease }
enum MusicResourceScope: String, Sendable { case catalog, library }
enum MusicRepeatMode: Sendable { case off, all, one }
enum MusicTrackIdentity { static func key(service: MusicServiceID, scope: MusicResourceScope, id: String) -> String { id } }
struct LyricsRenderConfiguration: Sendable { var backgroundBlur = 0.0; var showControls = false }
SWIFT

xcrun swiftc -o build/seek-loop/check \
 build/seek-loop/Models.swift build/seek-loop/Stubs.swift AMLLPlayer/Domain/PlaybackModels.swift \
 AMLLPlayer/Rendering/{AMLLFrameEngine,AMLLDisplayDocument,AMLLMotionModel,AMLLSourceTimeline,AMLLSourceSpring,AMLLScheduledSpring,AMLLSourceTransition,AMLLWordAnimationClock,AMLLFocusRetirement,AMLLMaskAlpha}.swift \
 Scripts/debug-lyrics-seek/main.swift
time build/seek-loop/check
