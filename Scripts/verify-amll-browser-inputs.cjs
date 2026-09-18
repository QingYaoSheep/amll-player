// Verify the committed dependency-code baseline without installing new packages.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const legacy = path.resolve(process.argv[2] || path.join(root, '..', 'AMLL-OLD'));
const baseline = JSON.parse(fs.readFileSync(path.join(root, 'ReferenceCaptures/amll-browser-inputs.json'), 'utf8'));
let failed = false;
for (const input of baseline.inputs) {
  const file = path.resolve(legacy, input.file);
  if (![root, legacy].some(base => file.startsWith(base + path.sep))) {
    throw new Error(`Reference escaped approved source roots: ${input.file}`);
  }
  const actual = fs.existsSync(file)
    ? crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') : 'missing';
  if (actual !== input.sha256) {
    failed = true;
    console.error(`Reference drift: ${input.file}`);
  }
}
if (failed) process.exitCode = 1;
else console.log(`Verified ${baseline.inputs.length} pinned core-browser inputs (core ${baseline.core}).`);
