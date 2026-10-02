# Real decoded seek probe

Development-only. The app does not embed these scripts or test audio.

The fixtures are synthetic 48-second mono audio, 44.1 kHz. Each two-second slot has tone frequency 320 + slot * 80 Hz. Alternating amplitude creates variable FLAC frames. Fixtures are bundled only in the test target.

Start the local byte-range HTTP server:

    node Scripts/debug-lyrics-seek-v2/server.cjs AMLLPlayerTests/Fixtures

On macOS compare the same decoder and input with one asset option changed:

    xcrun swift Scripts/debug-lyrics-seek-v2/Audio.swift AMLLPlayerTests/Fixtures --http
    xcrun swift Scripts/debug-lyrics-seek-v2/Audio.swift AMLLPlayerTests/Fixtures --http --precise

Baseline exits 1 when audible marker content disagrees with the requested slot; precise exits 0 when all targets agree. PCM comes from MTAudioProcessingTap, not a mock clock. This detects wrong content, independently of AVPlayer.currentTime.

Permanent iOS regression uses NetEasePlayback.makeAudioItem (the production asset factory), the same fixtures and the actual decoder. Hosted production-page regression uses AppModel, AMLLLyricsPlayer, UIKit row activation and CADisplayLink. Device account audio, compressed-source time accuracy and visual acceptance remain separate.

The GitHub reproduction workflow belongs only to the diagnostic branch. Production keeps the original independent direct IPA and tests-then-IPA workflow.
