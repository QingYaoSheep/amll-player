import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const root = path.resolve(process.argv[2] ?? 'E:/REA/.analysis/rea-family2-20261108');
const destination = fileURLToPath(new URL('../AMLLPlayerTests/Fixtures/', import.meta.url));
const summary = JSON.parse(fs.readFileSync(path.join(root, 'pair-summary.json'), 'utf8'));
const state = r => [r.cursor, r.from, r.to, r.elapsed, r.duration, r.active, r.lastIndex, r.suppressed];
const result = [];
for (const capture of summary.captures) {
  const file = path.join(root, `${capture.preset}.frames.jsonl`);
  const digest = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) digest.update(chunk);
  assert.equal(digest.digest('hex'), capture.artifacts.frames.sha256);
  const points = [], gates = [], calls = [], steps = [], draws = [];
  const segments = [];
  const intern = tail => {
    const value = tail.map(s => [s.start, s.end, s.distance, s.count, s.final]);
    const index = segments.findIndex(s => JSON.stringify(s) === JSON.stringify(value));
    if (index >= 0) return index;
    segments.push(value);
    return segments.length - 1;
  };
  let records;
  for await (const line of readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity })) {
    const frame = JSON.parse(line);
    if (frame.hold.sampled) gates.push([frame.hold.b814, frame.hold.tickets.length, frame.hold.main ? 1 : 0]);
    if (frame.selector) {
      const s = frame.selector;
      const mapped = s.records.map(r => ({ index: r.key, start: r.start, end: r.end,
        lastWordEnd: r.lastWordEnd, interlude: !!r.flag20 }));
      if (records) assert.deepEqual(mapped, records);
      records = mapped;
      points.push({ now: s.nowArg, selected: s.input.active, pending: s.input.pending,
        kind: s.type, catchUp: s.catchup, enter: s.enter, removed: s.exit,
        active: s.output.active, display: s.output.display, next: s.output.pending, lead: s.lead });
    }
    for (let i = 0; i < frame.events.length; i++) {
      const before = frame.events[i], after = frame.events[i + 1];
      if (before.kind === 'catchup-call') {
        assert.equal(after.kind, 'catchup-return');
        calls.push({ eligible: !!before.row.firstWordTimed,
          before: before.row.runs.map(state), after: after.row.runs.map(state),
          segments: before.row.runs.map(r => intern(r.tail)) });
      }
      if (before.kind === 'run-before' && after?.kind === 'run-after' &&
          ((before.row.index === 1 && frame.now >= 6.5 && frame.now <= 8) ||
           (before.row.index === 5 && frame.now >= 20.5 && frame.now <= 22))) {
        steps.push({ now: frame.now, delta: frame.dt, enabled: !!before.row.updateEnabled,
          before: before.row.runs.map(state), after: after.row.runs.map(state),
          segments: before.row.runs.map(r => intern(r.tail)) });
      }
      if (before.kind === 'draw-window' && after?.kind === 'draw-shader' && frame.now >= 7.39 && frame.now <= 7.44) {
        draws.push({ cursor: before.row.runs[before.group].cursor, left: before.left, right: before.right,
          colors: after.colors });
      }
    }
  }
  result.push({ preset: capture.preset, wordVersion: capture.preset === '26.4' ? 1 : 3,
    frames: capture.completeFrames, sha256: capture.artifacts.frames.sha256,
    records, points, gates, calls, steps, segments, draws });
  console.log(JSON.stringify({ preset: capture.preset, points: points.length, gates: gates.length,
    calls: calls.length, steps: steps.length, segments: segments.length }));
}
const ttml = fs.readFileSync(path.join(root, 'family2-cases.ttml'));
assert.equal(crypto.createHash('sha256').update(ttml).digest('hex'), summary.fixture[0].sha256);
fs.writeFileSync(path.join(destination, 'blossom-family2.ttml'), ttml);
fs.writeFileSync(path.join(destination, 'blossom-family2-trace.json'), JSON.stringify(result) + '\n');
