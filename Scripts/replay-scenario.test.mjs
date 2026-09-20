import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {replaySteps} from './reference-browser/replay-scenario.mjs';
const scenario=JSON.parse(fs.readFileSync(new URL('../AMLLPlayer/Resources/amll-shared-replay.json',import.meta.url)));
test('shared fixture applies events before frame delta and holds paused song time',()=>{
  const frames=replaySteps(scenario);
  assert.equal(frames.length,480);
  assert.equal(frames[120].position,5);
  assert.equal(frames[179].position,5);
  assert.ok(frames[180].position>5);
  assert.equal(frames[120].seeking,true);
  assert.equal(frames[121].seeking,false);
  assert.equal(frames[121].revision,1);
  assert.deepEqual(replaySteps(scenario),frames);
});
test('rejects malformed events before executing a replay',()=>{
  for(const event of [{frame:-1,kind:'play'},{frame:0,kind:'seek'},
    {frame:0,kind:'seek',value:-1},{frame:0,kind:'unknown'}]) {
    assert.throws(()=>replaySteps({...scenario,events:[event]}));
  }
  assert.throws(()=>replaySteps({...scenario,events:[{frame:2,kind:'play'},{frame:1,kind:'pause'}]}));
});
