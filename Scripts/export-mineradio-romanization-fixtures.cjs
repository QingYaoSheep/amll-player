// Development-only: captures the pinned source engine output for native tests.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const source = process.argv[2];
const destination = process.argv[3];
if (!source || !destination) throw new Error('Usage: node export-mineradio-romanization-fixtures.cjs <Mineradio root> <output.json>');
const { RomanizationEngine } = require(path.join(source, 'romanization-engine.js'));
const samples = [
  ['Japanese mixed', '君の名は Baby', ''],
  ['Japanese kana', 'きょうはちょっといい日', 'ja'],
  ['Japanese sokuon', '学校でハッピー', 'ja'],
  ['Japanese punctuation', 'ありがとう、君。', 'ja'],
  ['Korean liaison', '널 부를래 Baby', ''],
  ['Korean mixed', '사랑해, Hello!', 'ko'],
  ['Korean palatalization', '같이 있어', 'ko'],
  ['Chinese exclusion', '我爱你', ''],
  ['Latin exclusion', 'Hello world', ''],
];
(async () => {
  const engine = new RomanizationEngine();
  const cases = [];
  for (const [name, text, languageHint] of samples) {
    const result = await engine.romanizeLines([{ text, karaokeTimeline: [] }], { languageHint });
    cases.push({ name, text, languageHint, lines: result.lines.map((line) => ({
      text: line.text,
      language: line.language,
      coverage: line.coverage,
      tokens: line.tokens.map((token) => ({
        sourceText: token.sourceText, romanized: token.romanized,
        utf16Start: token.c0, utf16End: token.c1,
      })),
    })) });
  }
  const sourceSha256 = crypto.createHash('sha256').update(fs.readFileSync(path.join(source, 'romanization-engine.js'))).digest('hex');
  fs.writeFileSync(destination, JSON.stringify({ sourceSha256, cases }, null, 2) + '\n');
  console.log(`Exported ${cases.length} source cases`);
})().catch((error) => { console.error(error); process.exitCode = 1; });
