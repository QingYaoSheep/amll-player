// Offline reference harness. Executes only the parser helpers from the locally supplied
// MIT-tagged spotify-multisource-lyrics.js v0.29.21, never its plugin/network/UI code.
// Usage: node Scripts/compare-legacy-lyrics.cjs <legacy-plugin-path>
// Install jsdom under ignored .build-tools/dom; stdout is the golden semantic projection.
const fs = require('node:fs');
const vm = require('node:vm');
const { JSDOM } = require('../.build-tools/dom/node_modules/jsdom');
const source = fs.readFileSync(process.argv[2], 'utf8');
if (!source.includes('// @version 0.29.21') || !source.includes('// @license MIT')) throw Error('Unexpected reference version/license');
const lines = source.split(/\r?\n/);
const start = lines.findIndex(line => line.startsWith('const tm='));
const end = lines.findIndex(line => line.startsWith('function effectiveAppleLang'));
if (start < 0 || end <= start) throw Error('Parser boundaries changed');
const sandbox = { DOMParser: new JSDOM('').window.DOMParser };
vm.createContext(sandbox);
vm.runInContext(lines.slice(start, end).join('\n'), sandbox, { timeout: 3000 });
if (process.argv.includes('--lrc')) {
  const beginLRC = lines.findIndex(line => line.startsWith('function fracMs'));
  const endLRC = lines.findIndex(line => line.startsWith('function simText'));
  if (beginLRC < 0 || endLRC <= beginLRC) throw Error('LRC boundaries changed');
  vm.runInContext(lines.slice(beginLRC, endLRC).join('\n'), sandbox, { timeout: 3000 });
  sandbox.input = JSON.parse(fs.readFileSync('AMLLPlayerTests/Fixtures/lrc-semantic.input.json', 'utf8'));
  const lrc = vm.runInContext('lrcToLines(input.original, input.translation, input.romanization, input.durationMs)', sandbox, { timeout: 3000 });
  // Native lines use half-open intervals, not the legacy inclusive millisecond end.
  // A legacy whole-line word is intentionally not promoted to native word timing.
  const normalized = lrc.map((line, i) => ({ text: line.words.map(w => w.word).join(''),
    start: line.startTime / 1000, end: (i + 1 < lrc.length ? lrc[i + 1].startTime : line.endTime) / 1000,
    translation: line.translatedLyric, romanization: line.romanLyric }));
  process.stdout.write(JSON.stringify(normalized, null, 2) + '\n');
  process.exit(0);
}
sandbox.xml = fs.readFileSync('AMLLPlayerTests/Fixtures/apple-semantic.ttml', 'utf8');
const result = vm.runInContext('parseTTML(xml, "zh-Hans-CN")', sandbox, { timeout: 3000 });
const golden = result.map(line => ({
  text: line.words.map(word => word.word).join(''), start: line.startTime / 1000, end: line.endTime / 1000,
  translation: line.translatedLyric, romanization: line.romanLyric, isBackground: line.isBG, isDuet: line.isDuet,
  words: line.words.map(word => ({ text: word.word, start: word.startTime / 1000, end: word.endTime / 1000, romanWord: word.romanWord || null }))
}));
process.stdout.write(JSON.stringify(golden, null, 2) + '\n');
