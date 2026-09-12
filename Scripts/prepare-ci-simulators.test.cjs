const { test } = require('node:test');
const assert = require('node:assert/strict');
const { selectRuntime } = require('./prepare-ci-simulators.cjs');
const runtime = (version, available = true, platform = 'iOS') => ({
  identifier: `com.apple.CoreSimulator.SimRuntime.${platform}-${version.replaceAll('.', '-')}`,
  version, isAvailable: available,
});
test('selects newest available iOS 26 runtime, never the incompatible latest major', () => {
  assert.equal(selectRuntime([runtime('27.0'), runtime('26.1'), runtime('26.10'),
    runtime('26.11', false), runtime('26.12', true, 'tvOS')]), runtime('26.10').identifier);
});
test('missing runtime fails explicitly instead of changing reference device or OS', () => {
  assert.throws(() => selectRuntime([runtime('27.0'), runtime('26.0', false)]), /No available iOS 26/);
});
