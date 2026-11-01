# Apple Music run production adapter — 2026-11-01

This increment connects the previously test-only cursor model to native lyric masks for Apple Music 16.4 style. AMLL keeps its existing masks. Source timestamps remain unchanged; independent romanization uses its own row clock. SDR and HDR consume the same per-row sample.

## Implemented
- Whitespace records retain provider word timing and measured glyph widths; adjacent equal-time pieces merge through the cursor model.
- A 30 physical-pixel window and 2 physical-pixel offset are converted once to native points. The user's gradient-width multiplier still applies.
- Deterministic normal-path cursor reconstruction supports native seek, recycling and relayout without inheriting a completed mask.
- Scale waits use absolute deadlines and consume the remainder of the start frame. Repeat layout does not restart a pending wait.
- Focused dark alpha is normalized against the existing 0.85 parent contribution, using the observed 0.30 endpoint.

## Explicit adaptation boundaries
The native adapter reconstructs the normal cursor at segment boundaries, rather than claiming identical source frame installation times. Source force/resync paths remain independently tested; unknown native event mappings are not guessed. Source selection and record production are adapted to native line groups and Core Text fragments. A fragment crossing multiple independent records falls back to the existing mask. Native Y scheduling and existing retirement logic remain in place. These are not a complete binary-identical port.

The 0.9-second predicate clears scale waiting only; it never shortens word durations or forces fill to 100%. No source-derived claim of last-word forced completion is made.

## Validation status
New tests cover record ownership, pixel conversion, deterministic reconstruction, Unicode whitespace, mixed-record fallback and scale deadlines. Local diff whitespace checks pass. Windows has no Swift/Xcode toolchain; compilation, algorithm tests and device visual/performance checks remain pending. Review agents could not complete due to service usage limits. No device parity claim is made.
