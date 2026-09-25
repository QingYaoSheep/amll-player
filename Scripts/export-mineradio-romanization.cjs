// Development-only exporter. The iOS app reads the resulting native binary
// resources; it never executes the JavaScript packages used to create them.
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const crypto = require('node:crypto');

const sourceRoot = process.argv[2];
const destination = process.argv[3];
if (!sourceRoot || !destination) {
  throw new Error('Usage: node export-mineradio-romanization.cjs <Mineradio root> <resource directory>');
}
const dictionaryRoot = path.join(sourceRoot, 'node_modules', 'kuromoji', 'dict');
const wanakana = require(path.join(sourceRoot, 'node_modules', 'wanakana'));
const names = [
  'base', 'check', 'tid', 'tid_pos', 'tid_map', 'cc',
  'unk', 'unk_pos', 'unk_map', 'unk_char', 'unk_compat', 'unk_invoke',
];
fs.mkdirSync(destination, { recursive: true });
const manifest = { source: 'Mineradio-Spotify kuromoji 0.1.2 and wanakana 5.3.1', files: {} };
manifest.mineradioEngineSha256 = crypto.createHash('sha256')
  .update(fs.readFileSync(path.join(sourceRoot, 'romanization-engine.js'))).digest('hex');
for (const name of names) {
  const original = fs.readFileSync(path.join(dictionaryRoot, `${name}.dat.gz`));
  const raw = zlib.gunzipSync(original);
  // Compression.framework's ZLIB decoder consumes raw DEFLATE. Keep the
  // decoded size in a fixed little-endian header for bounded allocation.
  const payload = zlib.deflateRawSync(raw, { level: 9 });
  const header = Buffer.alloc(4);
  header.writeUInt32LE(raw.length);
  const output = Buffer.concat([header, payload]);
  const file = `roman-${name}.deflate`;
  fs.writeFileSync(path.join(destination, file), output);
  manifest.files[file] = {
    sha256: crypto.createHash('sha256').update(output).digest('hex'),
    decodedBytes: raw.length,
    decodedSha256: crypto.createHash('sha256').update(raw).digest('hex'),
    sourceSha256: crypto.createHash('sha256').update(original).digest('hex'),
  };
}

// Generate the actual WanaKana mapping rather than maintaining a second
// independent romanization table by hand. Context rules (sokuon/long vowels)
// stay in Swift because they depend on neighboring characters.
const map = {};
const kana = [];
for (let code = 0x3040; code <= 0x30ff; code++) {
  const character = String.fromCharCode(code);
  const roman = wanakana.toRomaji(character, { convertLongVowelMark: true });
  if (roman !== character) { map[character] = roman; kana.push(character); }
}
for (const left of kana) for (const right of kana) {
  const pair = left + right;
  const roman = wanakana.toRomaji(pair, { convertLongVowelMark: true });
  if (roman !== (map[left] || left) + (map[right] || right)) map[pair] = roman;
}
for (const sokuon of ['っ', 'ッ']) for (const left of kana) for (const right of kana) {
  const triple = sokuon + left + right;
  const roman = wanakana.toRomaji(triple, { convertLongVowelMark: true });
  if (roman !== (map[sokuon + left] || (map[sokuon] || sokuon) + (map[left] || left))
      + (map[right] || right)) map[triple] = roman;
}
const mapping = Buffer.from(JSON.stringify(map));
fs.writeFileSync(path.join(destination, 'roman-kana-map.json'), mapping);
manifest.files['roman-kana-map.json'] = {
  sha256: crypto.createHash('sha256').update(mapping).digest('hex'),
  entries: Object.keys(map).length,
};
fs.writeFileSync(path.join(destination, 'romanization-resources.json'),
  JSON.stringify(manifest, null, 2) + '\n');
console.log('Exported pinned Japanese dictionary and kana mappings:',
  names.length, 'dictionary files,', Object.keys(map).length, 'kana mappings');
