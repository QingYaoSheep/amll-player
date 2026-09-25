const assert = require('node:assert/strict');
const test = require('node:test');
const { compare } = require('./compare-amll-performance.cjs');

const fixture = (p95) => ({
  sourceID: 'fixture', documentHash: 'fixed-document', viewport: { width: 402, height: 700 }, displayScale: 3,
  configuration: { fontSize: 32 },
  summary: { targetFPS: 120, frames: 900, cpu: { p95 }, longFrames: 10, peakCacheBytes: 1048576 },
});

test('reports like-for-like P95 improvement', () => {
  assert.equal(compare(fixture(6), fixture(4)).improvementPercent, 33.3);
});

test('rejects changed viewport or rendering configuration', () => {
  const changed = fixture(4);
  changed.viewport.width = 430;
  assert.throws(() => compare(fixture(6), changed), /Different performance input: viewport/);
});

test('rejects a changed lyric document even when the source ID matches', () => {
  const changed = fixture(4);
  changed.documentHash = 'different-lyrics';
  assert.throws(() => compare(fixture(6), changed), /Different performance input: documentHash/);
});
