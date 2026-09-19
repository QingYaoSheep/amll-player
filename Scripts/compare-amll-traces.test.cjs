const { test } = require('node:test');
const assert = require('node:assert/strict');
const { compare } = require('./compare-amll-traces.cjs');
function trace() {
  return { schema: 2, coreVersion: '0.5.2', environment: { width: 402 }, fps: 60,
    lineIDs: ['line'], breaks: [[]], frames: Array.from({ length: 20 }, (_, i) => ({
      lyricTime: i / 60, animationTime: i / 60, focusGroup: 0, browsing: false,
      rows: [{ lineIndex: 0, groupIndex: 0, active: true, hidden: false,
        y: 100, scale: 1, opacity: 0.85, brightAlpha: 1, darkAlpha: 0.3 }],
    })) };
}
test('identical complete traces pass', () => assert.equal(compare(trace(), trace()).passed, true));
test('one large position outlier is excluded by nearest-rank P95, two fail', () => {
  const candidate = trace();
  candidate.frames[0].rows[0].y += 20;
  assert.equal(compare(trace(), candidate).passed, true);
  candidate.frames[1].rows[0].y += 20;
  assert.equal(compare(trace(), candidate).passed, false);
});
test('opacity and scale inspect all intermediate samples', () => {
  for (const [key, error] of [['opacity', 0.03], ['darkAlpha', 0.03], ['scale', 0.003]]) {
    const candidate = trace(); candidate.frames[9].rows[0][key] += error;
    assert.equal(compare(trace(), candidate).passed, false);
  }
});
test('incompatible input and missing or malformed samples are rejected', () => {
  for (const mutate of [t => t.frames.pop(), t => t.frames[0].rows.pop(),
    t => t.environment.width++, t => t.breaks[0].push(3), t => t.frames[0].lyricTime++,
    t => t.frames[0].rows[0].hidden = true, t => t.frames[0].rows[0].y = null]) {
    const candidate = trace(); mutate(candidate);
    assert.throws(() => compare(trace(), candidate));
  }
});
