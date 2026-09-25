const assert = require('node:assert/strict');
const fs = require('node:fs');

function compare(baseline, optimized) {
  for (const key of ['sourceID', 'documentHash', 'viewport', 'displayScale', 'configuration']) {
    assert.deepEqual(optimized[key], baseline[key], `Different performance input: ${key}`);
  }
  assert.ok(baseline.summary?.frames > 0 && optimized.summary?.frames > 0, 'No sampled frames');
  assert.equal(optimized.summary.targetFPS, baseline.summary.targetFPS, 'Different refresh target');
  const before = baseline.summary.cpu.p95;
  const after = optimized.summary.cpu.p95;
  assert.ok(Number.isFinite(before) && before > 0 && Number.isFinite(after) && after >= 0);
  return {
    frames: [baseline.summary.frames, optimized.summary.frames],
    cpuP95Milliseconds: [before, after],
    improvementPercent: Math.round((1 - after / before) * 1000) / 10,
    longFrames: [baseline.summary.longFrames, optimized.summary.longFrames],
    peakCacheMiB: [baseline.summary.peakCacheBytes, optimized.summary.peakCacheBytes]
      .map(bytes => Math.round(bytes / 1048576 * 10) / 10),
  };
}

if (require.main === module) {
  const [before, after] = process.argv.slice(2);
  if (!before || !after) {
    console.error('Usage: node Scripts/compare-amll-performance.cjs before.json after.json');
    process.exitCode = 2;
  } else {
    console.log(JSON.stringify(compare(JSON.parse(fs.readFileSync(before)), JSON.parse(fs.readFileSync(after))), null, 2));
  }
}

module.exports = { compare };
