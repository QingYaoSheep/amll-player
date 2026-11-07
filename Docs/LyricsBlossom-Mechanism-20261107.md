# Apple Music run mechanism integration — 2026-11-07

Authority: E:/REA/.analysis/reports/SCROLL-SYLLABLE-MECHANISM-2026-11-07.md, target SHA d64d2b413c1abbc0b4ea57d4530e31e344ecb0b172b79fb8604d70c2185f98ed. This report supersedes the older whitespace-run, fixed-screen-pixel and force/paused interpretations.

## Production changes
- Apple Music hides and ignores user advance/gradient-width controls. Their persisted values remain available to AMLL.
- Native word fragments are grouped by actual visual row/direction. Source units crossing layout groups get width-weighted subintervals; source documents are unchanged. Adjacent equal-time fragments merge; counts are UTF-8 bytes excluding ASCII space. Unmapped RTL groups retain the established mask.
- Engine-owned run entries retain all cursor fields across view recycling. Normal step ordering, final-tail extension and forced exponential follow are shared with the reference model. Accurate native reconstruction is used for confirmed seeks/offset changes/layout changes.
- Progress-control drafts are independent of confirmed playback. Only that input selects exponential follow; lyric list browsing does not. Cancel, background and disappearance clear preview state.
- Drawing-space window is 30 with offset 2 on the native untransformed raster surface, converted to points once and then transformed with the row. This is a native raster convention, not universal source-device parity. SDR/HDR use the same sample.
- Ordinary selection uses the fixed convergence lead; family2/3 keep the native selection path at real time. No per-frame record sorting. An adaptive formula is testable but its switch remains unmapped and disabled.

## Deliberately gated source behavior
The source checker, 0.25-second catch-up installation, suppressed latch and strict takeover guards are implemented as independent interfaces. Native documents do not supply the required source record flags or hold-container state. Consequently production takeover/catch-up remain disabled and the exported frame diagnostic says why. Unknown values are not replaced by false/allowed flags. Ordinary early selection is a documented native selection-record adaptation, not complete source capacity/flag parity. Family2/3 catch-up remains gated for the same reason.

No fixed last-word cutoff or forced-fill denominator exists. Independent romanization uses its own layout and TTML times, and never inherits a body catch-up event.

## Review and validation
Two-axis read-only review identified offset reanchoring, recycled-layout identity, overlapping family2/3 focus and per-frame record sorting. These were corrected with regression cases. No documented standards violation was reported. Static diff checks pass. Swift compilation, scoped/full CI and device visual/performance results are recorded separately after execution. Prior source trace agreement is not counted as current native device validation.

## Build attempt
2026-11-07: commit dc4eae8c was pushed. No new workflow run appeared. Explicit ci.yml dispatch returned HTTP 422: `Actions has been disabled for this repository.` The workflow metadata remains active and the permissions endpoint says enabled=true, so this is an execution-side block, not evidence that source compilation failed. No permission settings were changed. WSL launch also fails with 0xd0000022; no usable local Swift/Xcode toolchain is available. Swift tests, full regression, IPA output and device acceptance remain unexecuted for this increment.
## Catch-up scheduling and animation tickets

Source inputs are the 2026-11-07 `CATCHUP-SCHEDULING` report, `scheduling-reference.mjs`, and the paired default 16.4 and 16.4 advance captures. The committed TTML has SHA-256 `6c47e7e0d008332e4aabc3d508a1623965c837b9a99baabd482bc37bc59f4a30`. The compact test fixture extracts inputs and observed outputs from 711 and 5,726 selector points. The source counters are 256 calls, 15 newly armed runs, and 241 suppressed calls. Input capture hashes are `3b4b012ee30d0f6e3632f364c1b12103d53069271627eec9bcfc0dfb56065ab5` and `986cd40f8ff50c472c0c24a3b953b0bb242708fbe00d388114b82afed71450a1`.

| Behavior | Production policy |
|---|---|
| Default 16.4 | Stateful family 3 with a display-clock selector pulse, one generation-tagged position ticket, and an independent media-clock subgate. |
| 16.4 advance | Ordinary preview and selection are separate. Preview code 1 dispatches the old active set. Code 2 does not. Actual position, scale, light and opacity commands provide the native hold tickets. |
| Lead | Both formulas are covered by the capture replay. Captured calls used the recorded adaptive setting, while production selects each family's fixed lead until the adaptive switch has a confirmed app mapping. |
| Run state | Existing interpolation advances before dispatch. Selection entry and exit control retargeting for family 3. Catch-up is a separate 250 ms interpolation with a suppression latch. |
| Clock and geometry | Confirmed seeks reconstruct at media time. Native Core Text grouping, width, and native motion geometry remain the production coordinate system. The position and spring channels test their own pending/completion state and derivatives. The timed channels use elapsed duration. The captured hold gates are fixture inputs only. |
| Compatibility limits | Family 2 uses the prior native path. The selected presets adapt source events to native appearance and motion channels. Exact source channel constants and completion polarity for every command, complex layout grouping, and unobserved rebase paths remain device comparison work. |

The paired fixture isolates selector and arming behavior from the original application's hold generator. Separate engine tests exercise ticket expiry and TTML-driven tail catch-up at 60 Hz, 120 Hz and irregular intervals. Device cadence, visual handoff and audio acceptance remain separate from simulator tests.
