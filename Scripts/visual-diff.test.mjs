import test from 'node:test';
import assert from 'node:assert/strict';
import {validatePair,comparePixels} from './reference-browser/visual-diff.mjs';
const meta={lyricSHA256:'a'.repeat(64),artworkSHA256:'b'.repeat(64),scenarioSHA256:'c'.repeat(64),configurationSHA256:'d'.repeat(64),width:2,height:1,displayScale:3,frame:10,font:'SF Pro',coordinateSpace:'content-physical-pixels'};
test('rejects incompatible or missing capture inputs before comparison',()=>{
  validatePair(meta,{...meta});
  for(const key of Object.keys(meta))assert.throws(()=>validatePair(meta,{...meta,[key]:undefined}));
  assert.throws(()=>validatePair({...meta,width:0},{...meta,width:0}));
});
test('overlay never realigns displaced pixels and exposes alpha differences',()=>{
  const a=new Uint8ClampedArray([255,255,255,255,0,0,0,0]);
  const b=new Uint8ClampedArray([0,0,0,0,255,255,255,255]);
  const result=comparePixels(a,b);
  assert.equal(result.report.changedPixels,2);assert.equal(result.report.maximumChannelError,255);
  assert.deepEqual([...result.overlay],Array(8).fill(128));
  assert.equal(comparePixels(a,a).report.changedPixels,0);
  assert.equal(comparePixels(new Uint8ClampedArray(4),new Uint8ClampedArray([0,0,0,255])).difference[0],255);
  assert.throws(()=>comparePixels(a,b.slice(0,4)));
});
