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

## Family 2 production integration, 2026-11-13

The 2026-11-08 family-2 report supersedes the family-2 compatibility limit above. Both 26.4 (word version 1) and 27 (word version 3), including custom settings selecting the same family, now use the source selector and adaptive lead. Other families retain their existing lead policy. Family 2 uses the associated-row selection start, a 30 Hz pulse and generation-checked animation tickets, without a media-clock hold or the ordinary family's 0.9 s takeover predicate. Rebase retains every overlapping row.

Activity and display selection are tracked separately. Catch-up is consumed even with no selection transition. An exit key updates display and retires the old row even with no entry or catch-up. Commands installed for this exit can issue hold tickets. The old run interpolation advances before the selector; a new 250 ms catch-up starts from its current cursor and remains alive after display exit. Engine-owned run state survives view recycling. Active run motion prevents a playing frame from reporting settled.

The new captures correct the old color interpretation for the observed family-2 branch. A uniform base is drawn separately from a white highlight gradient whose alpha goes from 0.85 to zero. Native normalized focus channels are resolved into these two passes; the existing parent row opacity is applied once. SDR uses a lazily created base layer sharing the glyph image and transform; HDR uses two SrcOver geometry passes, with no extended gain on the base. At rest the native uniform text is retained. Unsupported layout ranges retain the original mask. Source pixel parity outside these observed branches remains unverified.

`Scripts/extract-blossom-family2.mjs` verifies and extracts the externally retained captures into a 480 KiB test fixture and the shared TTML. Original frame SHA-256 values are `9be50d2df3a4f92900f65c68804fcd7dbb6736e1ad96f7829a291a243133aa4e` (26.4) and `bf5c07c9d32e4894916c3bce970b4492961c218bd1692c8d20b93215a73bf8eb` (27). The fixture covers 1,006 selector returns, 1,428 observed ticket gates, 83 catch-up calls, 18 run arms and 983 row-update samples, including single-run and four-run tails. Observed gates are test inputs only. Independent native ticket, production-engine, seek and canvas tests remain separate acceptance checks.

Xcode compilation, simulator tests and device visual/performance acceptance are recorded separately after running. Existing unrelated working-tree replay changes are excluded from this feature.
