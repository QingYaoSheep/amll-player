const { test } = require('node:test');
const assert = require('node:assert/strict');
const { selectRuntime } = require('./prepare-ci-simulators.cjs');
const runtime = (version, available = true, platform = 'iOS') => ({
  identifier: `com.apple.CoreSimulator.SimRuntime.${platform}-${version.replaceAll('.', '-')}`,
  version, isAvailable: available,
});
test('selects newest available iOS 27 runtime, never the incompatible latest major', () => {
  assert.equal(selectRuntime([runtime('28.0'), runtime('27.1'), runtime('27.10'),
    runtime('27.11', false), runtime('27.12', true, 'tvOS')]), runtime('27.10').identifier);
});
test('missing runtime fails explicitly instead of changing reference device or OS', () => {
  assert.throws(() => selectRuntime([runtime('28.0'), runtime('27.0', false)]), /No available iOS 27/);
});
