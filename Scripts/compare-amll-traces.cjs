// Compare like-for-like native frame exports. An approved reference export is
// required; this does not turn a model trace into a browser or visual gold image.
const fs = require('node:fs');
const assert = require('node:assert/strict');

function compare(reference, actual) {
  assert.equal(reference.schema, 2, 'Expected schema 2 reference');
  assert.equal(actual.schema, 2, 'Expected schema 2 actual');
  for (const key of ['coreVersion', 'environment', 'fps', 'lineIDs', 'breaks']) {
    assert.deepEqual(actual[key], reference[key], `Incompatible ${key}`);
  }
  assert.ok(reference.frames?.length > 0, 'Empty reference');
  assert.equal(actual.frames?.length, reference.frames.length, 'Frame count differs');
  const errors = { position: [], opacity: [], scale: [] };
  const finite = value => { assert.ok(Number.isFinite(value), 'Non-finite sample'); return value; };
  reference.frames.forEach((frame, index) => {
    const candidate = actual.frames[index];
    for (const key of ['lyricTime', 'animationTime']) {
      assert.ok(Math.abs(finite(candidate[key]) - finite(frame[key])) <= 1e-6, `Frame ${index}: incompatible ${key}`);
    }
    for (const key of ['focusGroup', 'browsing']) {
      assert.equal(candidate[key], frame[key], `Frame ${index}: ${key}`);
    }
    assert.equal(candidate.rows.length, frame.rows.length, `Frame ${index}: row count`);
    frame.rows.forEach((row, rowIndex) => {
      const other = candidate.rows[rowIndex];
      for (const key of ['lineIndex', 'groupIndex', 'active', 'hidden']) {
        assert.equal(other[key], row[key], `Frame ${index}, row ${rowIndex}: ${key}`);
      }
      errors.position.push(Math.abs(finite(other.y) - finite(row.y)));
      errors.scale.push(Math.abs(finite(other.scale) - finite(row.scale)));
      for (const key of ['opacity', 'brightAlpha', 'darkAlpha']) {
        errors.opacity.push(Math.abs(finite(other[key]) - finite(row[key])));
      }
    });
  });
  assert.ok(errors.position.length, 'No row samples');
  errors.position.sort((a, b) => a - b);
  const report = {
    frames: reference.frames.length,
    positionP95: errors.position[Math.ceil(errors.position.length * 0.95) - 1],
    opacityMax: errors.opacity.reduce((a, b) => Math.max(a, b), 0),
    scaleMax: errors.scale.reduce((a, b) => Math.max(a, b), 0),
  };
  report.passed = report.positionP95 <= 1 && report.opacityMax <= 0.02 && report.scaleMax <= 0.002;
  return report;
}

if (require.main === module) {
  try {
    assert.equal(process.argv.length, 4, 'Usage: node Scripts/compare-amll-traces.cjs reference.json actual.json');
    const result = compare(...process.argv.slice(2).map(file => JSON.parse(fs.readFileSync(file, 'utf8'))));
    console.log(JSON.stringify(result, null, 2));
    process.exitCode = result.passed ? 0 : 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
module.exports = { compare };
