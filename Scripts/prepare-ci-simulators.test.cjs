const { test } = require('node:test');
const assert = require('node:assert/strict');
const { selectRuntime } = require('./prepare-ci-simulators.cjs');
const runtime = (version, available = true, platform = 'iOS') => ({
  identifier: `com.apple.CoreSimulator.SimRuntime.${platform}-${version.replaceAll('.', '-')}`,
  version, isAvailable: available,
  supportedDeviceTypes: ['iPhone-16-Pro', 'iPad-Pro-13-inch-M4-8GB'].map(name => ({ identifier: `com.apple.CoreSimulator.SimDeviceType.${name}` })),
});
test('selects newest available iOS 27 runtime, never the incompatible latest major', () => {
  assert.equal(selectRuntime([runtime('28.0'), runtime('27.1'), runtime('27.10'),
    runtime('27.11', false), runtime('27.12', true, 'tvOS')]), runtime('27.10').identifier);
});
test('missing runtime fails explicitly instead of changing reference device or OS', () => {
  assert.throws(() => selectRuntime([runtime('28.0'), runtime('27.0', false)]), /No available iOS 27/);
});
test('selects a runtime compatible with both fixed reference devices', () => {
  const incompatible = runtime('27.1');
  incompatible.supportedDeviceTypes = [{ identifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro' }];
  assert.equal(selectRuntime([runtime('27.0'), incompatible]), runtime('27.0').identifier);
  assert.throws(() => selectRuntime([incompatible]), /No available iOS 27/);
  incompatible.supportedDeviceTypes = [{ identifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro' }];
  assert.throws(() => selectRuntime([incompatible]), /No available iOS 27/, 'The iPad reference must also be supported');
});
