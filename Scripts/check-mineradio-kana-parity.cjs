// Development-only full IPADIC reading comparison; requires the pinned source
// checkout and never enters the iOS application.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const source = process.argv[2];
if (!source) throw new Error('Usage: node check-mineradio-kana-parity.cjs <Mineradio root>');
const wanakana = require(path.join(source, 'node_modules', 'wanakana'));
const map = require('../AMLLPlayer/Resources/Romanization/roman-kana-map.json');
const data = zlib.gunzipSync(fs.readFileSync(path.join(source, 'node_modules/kuromoji/dict/tid_pos.dat.gz')));

function nativeRules(reading) {
  const chars = [...reading];
  let output = '';
  for (let index = 0; index < chars.length;) {
    if (chars[index] === 'ー') {
      output += [...output].reverse().find((char) => 'aeiou'.includes(char)) || '-';
      index++;
      continue;
    }
    let matched = false;
    for (let length = Math.min(3, chars.length - index); length >= 1; length--) {
      const key = chars.slice(index, index + length).join('');
      if (index + length < chars.length && /[っッ]$/.test(key)
          && /[\u3040-\u30ff]/u.test(chars[index + length])) continue;
      if (map[key] !== undefined) {
        output += map[key];
        index += length;
        matched = true;
        break;
      }
    }
    if (!matched) output += chars[index++];
  }
  return output.toLowerCase();
}

let start = 0, checked = 0;
const seen = new Set();
for (let end = 0; end < data.length; end++) {
  if (data[end] !== 0) continue;
  const fields = data.subarray(start, end).toString('utf8').split(',');
  start = end + 1;
  for (const value of [fields[8], fields[9]]) {
    if (!value || value === '*' || seen.has(value)) continue;
    seen.add(value);
    const expected = wanakana.toRomaji(value, { convertLongVowelMark: true }).toLowerCase();
    const actual = nativeRules(value);
    assert.equal(actual, expected, `WanaKana mapping differs for ${value}`);
    checked++;
  }
}
console.log(`WanaKana mapping matches ${checked} pinned IPADIC readings`);
