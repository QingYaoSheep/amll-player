import {DomLyricPlayer} from 'pinned-amll-core';
import fixture from 'pinned-fixture';
import {ControlledClock} from './controlled-clock.mjs';

const viewport = document.querySelector('#viewport');
// The renderer lives in its own browsing context so vh/vw and media queries
// resolve against the reference viewport, not the adjacent measurement toolbar.
const controls = parent.document;
const parameters = new URLSearchParams(location.search);
const dimension = (name,fallback) => {
  const value = Number(parameters.get(name));
  return Number.isFinite(value) && value > 0 ? value : fallback;
};
const width = dimension('width',402);
const height = dimension('height',700);
const fontSize = dimension('font',fixture.fontSize);
const controlled = parameters.get('clock') === 'controlled';
const nativeFrame = requestAnimationFrame.bind(window);
const clock = controlled ? new ControlledClock() : null;
if(clock) clock.install(window);
viewport.style.width = width+'px'; viewport.style.height = height+'px';
const player = new DomLyricPlayer();
const element = player.getElement();
element.style.fontSize = fontSize+'px'; viewport.appendChild(element);
player.setAlignAnchor('top'); player.setAlignPosition(fixture.anchor);
let position = 1, playing = false, lastFrame, frameCount = 0;
const trace = [];
const lines = fixture.lines;
await document.fonts.ready;
await new Promise(nativeFrame);
player.setLyricLines(structuredClone(lines),position*1000);
player.pause();
if(clock) clock.advance(0);
else await new Promise(nativeFrame);
player.update(0);
if(clock) {
  // ResizeObserver / mutation promise work must finish before establishing the
  // deterministic origin. Native frames perform layout, never advance time.
  for(let i=0;i<4;i++) { await new Promise(nativeFrame); clock.advance(0); }
  player.setCurrentTime(position*1000,true); player.calcLayout(true,true); player.update(0);
}
clock?.capture(element);

function animationRecords() {
  const targetPath = target => {
    const indices = [];
    while(target && target !== element) {
      const parent = target.parentElement;
      if(!parent) break;
      indices.unshift([...parent.children].indexOf(target));
      target = parent;
    }
    return indices.join('/');
  };
  // getAnimations enumeration may change between style recalculations. Identify
  // effects by their DOM target and CSS property, never by sampled values.
  // Stable sort preserves composite order for effects sharing the same key.
  return element.getAnimations({subtree:true}).map(animation=>({
    target:targetPath(animation.effect?.target),
    property:animation.transitionProperty ?? animation.animationName ?? animation.id,
    id:animation.id,time:animation.currentTime,
    timing:animation.effect?.getTiming(),frames:animation.effect?.getKeyframes()
  })).sort((a,b)=>a.target.localeCompare(b.target) || a.property.localeCompare(b.property));
}

function capture(includeAnimations = false) {
  const root = viewport.getBoundingClientRect();
  const rect = element => {
    const value=element.getBoundingClientRect();
    return {x:value.x-root.x,y:value.y-root.y,width:value.width,height:value.height};
  };
  const groups = player.currentLyricGroups.map((group,index)=>({index,start:group.startTime,end:group.endTime,
    y:group.posY.getCurrentPosition(),slide:group.bgSlideY.getCurrentPosition(),active:group.isActive,
    rect:rect(group.element),opacity:getComputedStyle(group.element).opacity,filter:getComputedStyle(group.element).filter,
    lines:[group.mainLine,group.bgLine].filter(Boolean).map(line=>({
      text:line.getLine().words.map(word=>word.word).join(''),rect:rect(line.getElement()),
      scale:line.lineTransforms.scale.getCurrentPosition(),
      bright:getComputedStyle(line.getElement()).getPropertyValue('--bright-mask-alpha'),
      dark:getComputedStyle(line.getElement()).getPropertyValue('--dark-mask-alpha'),
      words:[...line.getElement().querySelectorAll('span')].map(word=>({text:word.textContent,rect:rect(word)}))
    }))}));
  return {position,playing,viewport:{width,height,fontSize,scale:devicePixelRatio,font:getComputedStyle(element).fontFamily},groups,
    animations:includeAnimations ? animationRecords() : undefined};
}
function step(delta, time = position + (playing ? delta : 0), seek=false) {
  clock?.advance(delta*1000);
  position=time;
  player.setCurrentTime(position*1000,seek); player.update(delta*1000);
  clock?.capture(element);
  frameCount++;
  // Geometry reads force style/layout. Opt in for measurement, keeping ordinary
  // playback free from capture overhead. Keyframe arrays are exported only once.
  if(controls.querySelector('#record').checked) {
    trace.push(capture()); if(trace.length>1200) trace.shift();
  }
  controls.querySelector('#status').textContent=JSON.stringify({position,playing,groups:player.currentLyricGroups.length,frames:frameCount,samples:trace.length,viewport:{width:innerWidth,height:innerHeight}},null,2);
}
async function controlledStep(delta,time,seek=false) {
  step(delta,time,seek);
  if(clock) {
    await new Promise(nativeFrame);
    clock.advance(0);await Promise.resolve();clock.capture(element);
  }
}
function frame(timestamp) {
  // pause() stops word playback; group springs must still settle every frame.
  step(lastFrame===undefined?0:(timestamp-lastFrame)/1000);
  lastFrame=timestamp; requestAnimationFrame(frame);
}
controls.querySelector('#step60').onclick=()=>controlledStep(1/60);
controls.querySelector('#step120').onclick=()=>controlledStep(1/120);
controls.querySelector('#clockMode').checked=controlled;
controls.querySelector('#clockMode').onchange=event=>{
  const url=new URL(parent.location.href); url.searchParams.set('clock',event.target.checked?'controlled':'realtime');
  parent.location.href=url;
};
controls.querySelector('#seek').onclick=()=>step(0,Number(controls.querySelector('#time').value)||0,true);
controls.querySelector('#play').onclick=()=>{playing=!playing; playing?player.resume():player.pause();lastFrame=undefined;};
controls.querySelector('#clear').onclick=()=>{trace.length=0;};
controls.querySelector('#export').onclick=()=>{
  const url=URL.createObjectURL(new Blob([JSON.stringify({schema:1,scope:controlled?'core-only; controlled timers/RAF/WAAPI/CSS sampling; pending browser parity validation':'core-only; real browser clock',animationTime:clock?.now,current:capture(true),trace},null,2)],{type:'application/json'}));
  const link=document.createElement('a');link.href=url;link.download='amll-original-core-trace.json';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
};
window.amllReference={capture,step:controlledStep,player,trace,clock};
step(0); document.documentElement.dataset.amllReady='true';if(!controlled) requestAnimationFrame(frame);
