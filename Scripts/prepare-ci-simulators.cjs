// Create explicit devices instead of relying on the runner's prebuilt inventory.
const { execFileSync } = require('node:child_process');
const { appendFileSync } = require('node:fs');

function selectRuntime(runtimes) {
  const candidates = runtimes.filter(runtime => runtime.isAvailable &&
    runtime.identifier.startsWith('com.apple.CoreSimulator.SimRuntime.iOS-') &&
    runtime.version.split('.')[0] === '26');
  candidates.sort((a, b) => b.version.localeCompare(a.version, 'en', { numeric: true }));
  if (!candidates.length) throw new Error('No available iOS 26 simulator runtime; install it before testing.');
  return candidates[0].identifier;
}

if (require.main === module) {
  const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8' }).trim();
  const runtime = selectRuntime(JSON.parse(simctl('list', 'runtimes', '--json')).runtimes);
  const types = JSON.parse(simctl('list', 'devicetypes', '--json')).devicetypes;
  for (const [key, name] of [['CI_IPHONE_UDID', 'iPhone 16 Pro'], ['CI_IPAD_UDID', 'iPad Pro 13-inch (M4)']]) {
    const type = types.find(value => value.name === name);
    if (!type) throw new Error(`Required simulator type is unavailable: ${name}`);
    const udid = simctl('create', `AMLL CI ${name}`, type.identifier, runtime);
    appendFileSync(process.env.GITHUB_ENV, `${key}=${udid}\n`);
    console.log(`${name}: ${udid} (${runtime})`);
  }
}

module.exports = { selectRuntime };
