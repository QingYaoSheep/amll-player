const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const root = path.join(__dirname, '..', 'AMLLPlayer', 'Resources', 'Romanization');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'romanization-resources.json')));
const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');
let total = 0;
for (const [name, record] of Object.entries(manifest.files)) {
  const data = fs.readFileSync(path.join(root, name));
  assert.equal(sha256(data), record.sha256, `Resource changed: ${name}`);
  total += data.length;
  if (!name.endsWith('.deflate')) continue;
  assert.equal(data.readUInt32LE(0), record.decodedBytes, `Decoded length: ${name}`);
  const decoded = zlib.inflateRawSync(data.subarray(4));
  assert.equal(decoded.length, record.decodedBytes, `Corrupt dictionary: ${name}`);
  assert.equal(sha256(decoded), record.decodedSha256, `Decoded hash: ${name}`);
}
assert.equal(Object.keys(manifest.files).length, 13);
console.log(`Pinned Mineradio dictionary verified: ${total} bytes packaged`);
