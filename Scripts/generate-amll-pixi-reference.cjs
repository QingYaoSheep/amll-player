// Evaluate pinned upstream onTick, not a second implementation of its formula.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const {stripTypeScriptTypes} = require('node:module');
const root = path.resolve(__dirname, '..');
const upstream = path.resolve(root, '../AMLL-OLD/node_modules/.pnpm');
const sourcePath = path.join(root, '.build-tools/amll-reference/core/src/bg-render/pixi-renderer.ts');
const raw = fs.readFileSync(sourcePath,'utf8');
const source = stripTypeScriptTypes('const '+raw.slice(raw.indexOf('onTick ='),raw.indexOf('constructor(')));
const tickBody = source.slice(source.indexOf('{')+1, source.lastIndexOf('}'));
const tick = vm.runInNewContext('(function(delta){'+tickBody+'})', {Math, clampPositive: x=>Math.max(0,x)});
const fixtures = [
  {name:'60Hz', steps:Array(120).fill(1/60)},
  {name:'120Hz', steps:Array(240).fill(1/120)},
  {name:'irregular', steps:[0,1/120,0.15,0.5,0,0.9,1/60]},
].map(({name,steps})=>{
  const sprites = [0,.5,1,2].map(rotation=>({rotation,position:{set(x,y){this.owner.x=x;this.owner.y=y;}}}));
  sprites.forEach(s=>s.position.owner=s);
  const ctx={lastContainer:new Set(),curContainer:{alpha:0,time:0,children:sprites},
    app:{screen:{width:600,height:900},ticker:{stop(){}}},flowSpeed:1,staticMode:false};
  const frames=steps.map(seconds=>{tick.call(ctx,seconds*60);return {time:ctx.curContainer.time,alpha:ctx.curContainer.alpha,
    sprites:sprites.map(s=>[s.x,s.y,s.width,s.rotation])};});
  return {name,steps,frames};
});
fs.writeFileSync(path.join(root,'AMLLPlayerTests/Fixtures/amll-pixi-reference.json'),JSON.stringify(fixtures)+'\n');
const files=[sourcePath];
files.push(path.join(upstream,'@pixi+ticker@7.4.3/node_modules/@pixi/ticker/lib/Ticker.mjs'));
for(const [pkg,version,subfiles] of [
 ['filter-blur','7.4.3',['lib/BlurFilterPass.mjs','lib/generateBlurFragSource.mjs','lib/BlurFilter.mjs','LICENSE']],
 ['filter-color-matrix','7.4.3',['lib/ColorMatrixFilter.mjs','lib/colorMatrix.frag.mjs','LICENSE']],
 ['filter-bulge-pinch','5.1.1',['dist/filter-bulge-pinch.mjs','LICENSE']],
]) for(const file of subfiles) files.push(path.join(upstream,`@pixi+${pkg}@${version}_@pixi+core@7.4.3/node_modules/@pixi/${pkg}`,file));
const manifest=files.map(file=>({path:path.relative(root,file).replaceAll('\\','/'),sha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}));
fs.writeFileSync(path.join(root,'ReferenceCaptures/amll-pixi-inputs.json'),JSON.stringify(manifest,null,2)+'\n');
console.log(`Exported ${fixtures.length} source trajectories and ${files.length} input hashes.`);
