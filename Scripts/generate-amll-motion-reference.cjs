// Execute the pinned, extracted TypeScript algorithms, never the application bundle.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const root = path.resolve(__dirname, '..');
const source = path.join(root, '.build-tools/amll-reference/core/src');
const baseline = JSON.parse(fs.readFileSync(path.join(root, 'ReferenceCaptures/amll-source-manifest.json'), 'utf8'));
const bezierPackage = baseline.dependencies.find(item => item.name === 'bezier-easing');
const bezierModule = require(path.join(root, '..', 'AMLL-OLD/node_modules/.pnpm', bezierPackage.installation));
const bezier = bezierModule.default || bezierModule;
const context = vm.createContext({ Intl, bezier });
for (const file of ['utils/derivative.ts', 'utils/spring.ts', 'utils/is-cjk.ts', 'utils/lyric-line-break.ts', 'utils/eq-set.ts', 'lyric-player/base/timeline.ts', 'utils/optimize-lyric.ts', 'utils/matrix.ts']) {
  const stripped = stripTypeScriptTypes(fs.readFileSync(path.join(source, file), 'utf8'))
    .replace(/^import\s.*?;\s*$/gm, '').replace(/\bexport /g, '');
  vm.runInContext(stripped, context, { filename: file });
}
// Run the original DOM class's two numeric methods with a minimal style sink.
// No copied Swift formulas are used to generate the expected alpha trajectory.
const domLine = fs.readFileSync(path.join(source, 'lyric-player/dom/lyric-line.ts'), 'utf8');
const alphaMethods = domLine.slice(domLine.indexOf('\tprivate updateMaskAlphaTargets('), domLine.indexOf('\toverride setTransform('));
if (!alphaMethods.includes('private applyAlphaToDom')) throw Error('Pinned alpha methods moved');
vm.runInContext(stripTypeScriptTypes(`class AlphaReference {
  currentBrightAlpha = 1; currentDarkAlpha = .2;
  targetBrightAlpha = 1; targetDarkAlpha = .2; renderMode = 0;
  output = {}; element = {style:{setProperty:(key,value)=>this.output[key]=Number(value)}};
  ${alphaMethods}
}`), context);
vm.runInContext('const clamp01 = x => Math.min(1,Math.max(0,x)); const LyricLineRenderMode = {SOLID:0,GRADIENT:1};', context);
const maskMethod = domLine.slice(domLine.indexOf('\tprivate generateWebAnimationBasedMaskImage('), domLine.indexOf('\tgetElement(): HTMLElement'));
const gradientFunction = domLine.slice(domLine.indexOf('function generateFadeGradient('), domLine.indexOf('export class LyricLineEl'));
vm.runInContext(stripTypeScriptTypes(`${gradientFunction}
const clamp = (x,min,max) => Math.min(max,Math.max(min,x));
const clampPositive = x => Math.max(0,x);
class MaskReference {
  supportMaskImage = true;
  lyricPlayer = {supportMaskImage:true,getWordFadeWidth:()=>.5};
  getRubySegments() { return []; }
  ${maskMethod}
}`), context);
const emphasisConstants = domLine.slice(domLine.indexOf('const ANIMATION_FRAME_QUANTITY'), domLine.indexOf('function generateFadeGradient'));
const emphasisMethods = domLine.slice(domLine.indexOf('\tprivate initFloatAnimation('), domLine.indexOf('\tprivate get totalDuration'));
vm.runInContext(stripTypeScriptTypes(`${emphasisConstants}
class EmphasisReference { ${emphasisMethods} }
`), context);
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
  const original = [
    {startTime:1000,endTime:2050,words:[{word:'a  b',startTime:1000,endTime:2050}],isBG:false},
    {startTime:900,endTime:2100,words:[{word:'echo',startTime:900,endTime:2100}],isBG:true},
    {startTime:2000,endTime:3000,words:[{word:'duet',startTime:2000,endTime:3000}],isBG:true},
    {startTime:2900,endTime:4500,words:[{word:'next',startTime:2900,endTime:4500}],isBG:false},
    {startTime:9000,endTime:10000,words:[{word:'end',startTime:9000,endTime:10000}],isBG:false}
  ];
  const optimized = JSON.parse(JSON.stringify(original));
  optimizeLyricLines(optimized);
  const alpha = [60,120].map(fps => {
    const state = new AlphaReference();
    const frames = [];
    for(let i=0;i<fps*3;i++) {
      const delta = i===12 ? .18 : i===0 ? 0 : 1/fps;
      const scale = i<fps ? .97+.035*Math.sin(i/fps*Math.PI/2) : i<fps*2 ? 1 : .75;
      const gradient = i<fps*2;
      state.renderMode = gradient ? 1 : 0;
      state.updateMaskAlphaTargets(scale); state.applyAlphaToDom(delta);
      frames.push({delta,scale,gradient,bright:state.output['--bright-mask-alpha'],dark:state.output['--dark-mask-alpha']});
    }
    return {fps,frames};
  });
  const mask = new MaskReference();
  mask.lyricLine = {startTime:400,endTime:5000};
  mask.splittedWords = [
    {word:'hold',startTime:1000,endTime:2300,width:80,height:38.4,padding:32},
    {word:'me',startTime:2800,endTime:3200,width:42,height:38.4,padding:32},
    {word:'近',startTime:3200,endTime:4600,width:32,height:38.4,padding:32}
  ].map(word => ({...word,maskAnimations:[],mainElement:{style:{},animate(frames,options) {
    this.capture = {frames,options}; return {pause(){},cancel(){}};
  }}}));
  mask.generateWebAnimationBasedMaskImage();
  const masks = mask.splittedWords.map(word => ({start:word.startTime/1000,end:word.endTime/1000,width:word.width,
    padding:word.padding,feather:word.height*.5,frames:word.mainElement.capture.frames.map(frame => ({
      time:(mask.lyricLine.startTime+frame.offset*word.mainElement.capture.options.duration)/1000,
      edge:parseFloat(frame.maskPosition)+word.width+word.padding
    }))}));
  const emphasis = [
    {duration:1800,delay:600,count:4,rubyCount:0,last:false,background:false},
    {duration:3500,delay:0,count:1,rubyCount:0,last:true,background:true},
    {duration:500,delay:-50,count:3,rubyCount:5,last:true,background:false}
  ].map(input => {
    const player = new EmphasisReference();
    player.lyricLine = {startTime:0,isBG:input.background,words:[{word:input.last?'held':'end'}]};
    const animations = [];
    const elements = Array.from({length:input.count},(_,index)=>({textContent:String(index),animate(frames,options) {
      animations.push({frames,options}); return {pause(){}};
    }}));
    player.initEmphasizeAnimation({word:'held'},elements,input.duration,input.delay,input.rubyCount);
    const characters = elements.map((_,i)=>{
      const glow = animations[i*2], floating = animations[i*2+1];
      return {delay:glow.options.delay/1000,duration:glow.options.duration/1000,
        floatDelay:floating.options.delay/1000,floatDuration:floating.options.duration/1000,
        frames:glow.frames.map((frame,j)=>{
          const transform = frame.transform.match(/matrix3d\\((.*?)\\) translate\\((.*?)em, (.*?)em\\)/);
          const shadow = frame.textShadow.match(/0 0 (.*?)em rgba\\(255, 255, 255, (.*?)\\)/);
          return {offset:frame.offset,scale:Number(transform[1].split(',')[0]),x:Number(transform[2]),y:Number(transform[3]),
            glowRadius:Number(shadow[1]),glowOpacity:Number(shadow[2]),floatY:parseFloat(floating.frames[j].transform.slice(11))};
        })};
    });
    return {input,characters};
  });
  return {traces,breaks,groups,timeline,original,optimized,alpha,masks,emphasis};
})()`, context);
const target = path.join(root, 'AMLLPlayerTests/Fixtures/amll-motion-reference.json');
const bytes = JSON.stringify(fixture, null, 2) + '\n';
if(process.argv.includes('--verify')) {
  if(fs.readFileSync(target,'utf8') !== bytes) throw Error('Motion reference differs');
} else fs.writeFileSync(target, bytes);
console.log(`Reference: ${fixture.traces.reduce((n,t)=>n+t.frames.length,0)} spring frames, ${fixture.breaks.length} layouts, ${fixture.timeline.length} timeline states`);
