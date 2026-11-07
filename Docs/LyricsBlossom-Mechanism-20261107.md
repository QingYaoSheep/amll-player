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
