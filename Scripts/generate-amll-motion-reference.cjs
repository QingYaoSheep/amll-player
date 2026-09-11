// Execute the pinned, extracted TypeScript algorithms, never the application bundle.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const root = path.resolve(__dirname, '..');
const source = path.join(root, '.build-tools/amll-reference/core/src');
const context = vm.createContext({ Intl });
for (const file of ['utils/derivative.ts', 'utils/spring.ts', 'utils/is-cjk.ts', 'utils/lyric-line-break.ts', 'utils/eq-set.ts', 'lyric-player/base/timeline.ts']) {
  const stripped = stripTypeScriptTypes(fs.readFileSync(path.join(source, file), 'utf8'))
    .replace(/^import\s.*?;\s*$/gm, '').replace(/\bexport /g, '');
  vm.runInContext(stripped, context, { filename: file });
}
const fixture = vm.runInContext(`(() => {
  const traces = [60, 120].map(fps => {
    const spring = new Spring(0);
    spring.updateParams({mass:0.9,damping:15,stiffness:90});
    spring.setTargetPosition(180, 0.05);
    const frames = [];
    for (let frame = 0; frame < fps * 2; frame++) {
      const delta = frame === 12 ? 0.18 : 1/fps;
      if (frame === 20) spring.setTargetPosition(-40, 0.025);
      if (frame === 35) spring.updateParams({damping:25,stiffness:170});
      spring.update(delta);
      frames.push({delta, value:spring.getCurrentPosition()});
    }
    return {fps,frames};
  });
  const texts = ['Bad, bad boy, shiny toy with a price', '你好，世界。一起唱歌', 'مرحبا بالعالم', 'a  b 👩‍👩‍👦 é fi'];
  const breaks = texts.map(text => {
    const children = [...text].map(text => ({text,width:text === ' ' ? 4:10,isSpace:/^\\s+$/.test(text)}));
    const boundaries = [];
    for(const s of new Intl.Segmenter('zh', {granularity:'word'}).segment(text)) {
      if(s.index > 0 && s.isWordLike && [...s.segment].some(isCJK)) boundaries.push(s.index);
    }
    return {children,width:80,boundaries,breaks:calcBalancedBreaks(children,80,text,new Intl.Segmenter('zh',{granularity:'word'}))};
  });
  const groups = [{startTime:400,endTime:2000},{startTime:1600,endTime:3200},{startTime:7000,endTime:8000}];
  const state = {currentTime:0,lastCurrentTime:0,hotGroups:new Set(),bufferedGroups:new Set(),scrollToIndex:0,isSeeking:false,isPlaying:true,initialLayoutFinished:true};
  const timeline = [0,400,1700,2100,3300,7000,8100,900,5000].map((time,i) => {
    state.isSeeking = i >= 7;
    const result = commitPlayerTimeState({timelineState:state,time,currentGroups:groups,hasBottomContent:false,stateResult:computePlayerTimeState({time,currentGroups:groups,timelineState:state})});
    return {time,seeking:state.isSeeking,hot:[...state.hotGroups].sort(),buffered:[...state.bufferedGroups].sort(),focus:state.scrollToIndex,layout:result.shouldLayout};
  });
  return {traces,breaks,groups,timeline};
})()`, context);
const target = path.join(root, 'AMLLPlayerTests/Fixtures/amll-motion-reference.json');
const bytes = JSON.stringify(fixture, null, 2) + '\n';
if(process.argv.includes('--verify')) {
  if(fs.readFileSync(target,'utf8') !== bytes) throw Error('Motion reference differs');
} else fs.writeFileSync(target, bytes);
console.log(`Reference: ${fixture.traces.reduce((n,t)=>n+t.frames.length,0)} spring frames, ${fixture.breaks.length} layouts, ${fixture.timeline.length} timeline states`);
