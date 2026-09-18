// Execute the pinned implementation with a reproducible Math.random stream.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const root = path.resolve(__dirname, '..');
const source = path.join(root, '.build-tools/amll-reference/core/src/bg-render/mesh-renderer');
let state = 1;
const math = Object.create(Math);
math.random = () => {
  state ^= state << 13; state ^= state >>> 17; state ^= state << 5;
  return (state >>> 0) / 4294967296;
};
const context = vm.createContext({Math: math});
vm.runInContext('const clamp01 = x => Math.min(1, Math.max(0,x));', context);
for (const file of ['cp-presets.ts', 'cp-generate.ts']) {
  const code = stripTypeScriptTypes(fs.readFileSync(path.join(source, file), 'utf8'))
    .replace(/^import[\s\S]*?;\s*$/gm, '').replace(/\bexport /g, '');
  vm.runInContext(code, context, { filename: file });
}
const presets = vm.runInContext('CONTROL_POINT_PRESETS', context);
const fixtures = [1, 42, 123456, 4294967295].map(seed => {
  state = seed;
  return {seed, preset: vm.runInContext('generateControlPoints(6,6)', context)};
});
fs.writeFileSync(path.join(root, 'AMLLPlayer/Resources/amll-mesh-presets.json'), JSON.stringify(presets, null, 2) + '\n');
fs.writeFileSync(path.join(root, 'AMLLPlayerTests/Fixtures/amll-background-reference.json'), JSON.stringify(fixtures, null, 2) + '\n');
console.log(`Exported ${presets.length} source presets and ${fixtures.length} seeded generator fixtures.`);
