import Foundation
func engine() -> AMLLFrameEngine {
 let lines = (0..<8).map { i in LyricLine(id: String(i), text: "Line \(i)", start: Double(i*4), end: Double(i*4+3), words: [.init(text: "Line", start: Double(i*4), end: Double(i*4+3))], precision: .word) }
 var env = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
 env.alignPosition = 0.28; env.advance = 0.3
 return AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines), environment: env, heights: Array(repeating: 60, count: lines.count))
}
var failures = 0
func check(_ condition: Bool, _ message: String) { if !condition { failures += 1; print("FAIL: " + message) } }
for step in [1.0/60, 1.0/120, 0.037] {
 var live = engine()
 _ = live.render(.init(position: 1, playing: true), delta: 0)
 live.handle(.beginBrowsing); live.handle(.browseBy(-200))
 let before = live.render(.init(position: 1, playing: true), delta: 0)
 let after = live.render(.init(position: 16, playing: true, seekRevision: 1, seekPosition: 16), delta: step)
 var fresh = engine(); let destination = fresh.render(.init(position: 16, playing: true), delta: 0)
 print("seek step=\(step) y: \(before.rows[4].y) -> \(after.rows[4].y), target=\(destination.rows[4].y)")
 check(abs(after.rows[4].y - destination.rows[4].y) > 1, "seek must retain intermediate spring positions")
 check(abs(after.rows[4].y - before.rows[4].y) < abs(destination.rows[4].y - before.rows[4].y), "seek must start from browsed presentation")
 check(after.rows[4].active && !after.rows[4].fillComplete, "seek singing state must use actual target")
}
if failures > 0 { exit(1) }
print("PASS: lyric seek motion regression")
