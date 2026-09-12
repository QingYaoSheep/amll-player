import {DomLyricPlayer} from 'pinned-amll-core';
import fixture from 'pinned-fixture';

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
const fontSize = dimension('font',Math.max(height*.05,width*.025,14));
viewport.style.width = width+'px'; viewport.style.height = height+'px';
const player = new DomLyricPlayer();
const element = player.getElement();
element.style.fontSize = fontSize+'px'; viewport.appendChild(element);
player.setAlignAnchor('top'); player.setAlignPosition(.1);
let position = 1, playing = false, lastFrame, frameCount = 0;
const trace = [];
const lines = fixture.original.map((line,index)=>({...line,isDuet:index===2,translatedLyric:`Translation ${index}`,romanLyric:'',
  words:line.words.map(word=>({...word,romanWord:''}))}));
await document.fonts.ready;
await new Promise(requestAnimationFrame);
player.setLyricLines(structuredClone(lines),position*1000);
player.pause();
await new Promise(requestAnimationFrame);
player.update(0);

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
    animations:includeAnimations ? element.getAnimations({subtree:true}).map(animation=>({id:animation.id,time:animation.currentTime,
      timing:animation.effect?.getTiming(),frames:animation.effect?.getKeyframes()})) : undefined};
}
function step(delta, time = position + (playing ? delta : 0), seek=false) {
  position=time;
  player.setCurrentTime(position*1000,seek); player.update(delta*1000);
  frameCount++;
  // Geometry reads force style/layout. Opt in for measurement, keeping ordinary
  // playback free from capture overhead. Keyframe arrays are exported only once.
  if(controls.querySelector('#record').checked) {
    trace.push(capture()); if(trace.length>1200) trace.shift();
  }
  controls.querySelector('#status').textContent=JSON.stringify({position,playing,groups:player.currentLyricGroups.length,frames:frameCount,samples:trace.length,viewport:{width:innerWidth,height:innerHeight}},null,2);
}
function frame(timestamp) {
  // pause() stops word playback; group springs must still settle every frame.
  step(lastFrame===undefined?0:(timestamp-lastFrame)/1000);
  lastFrame=timestamp; requestAnimationFrame(frame);
}
controls.querySelector('#step60').onclick=()=>step(1/60,position+1/60,true);
controls.querySelector('#step120').onclick=()=>step(1/120,position+1/120,true);
controls.querySelector('#seek').onclick=()=>step(0,Number(controls.querySelector('#time').value)||0,true);
controls.querySelector('#play').onclick=()=>{playing=!playing; playing?player.resume():player.pause();lastFrame=undefined;};
controls.querySelector('#clear').onclick=()=>{trace.length=0;};
controls.querySelector('#export').onclick=()=>{
  const url=URL.createObjectURL(new Blob([JSON.stringify({schema:1,scope:'core-only; CSS/WAAPI use browser time; step buttons seek, not deterministic animation stepping',current:capture(true),trace},null,2)],{type:'application/json'}));
  const link=document.createElement('a');link.href=url;link.download='amll-original-core-trace.json';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
};
window.amllReference={capture,step,player,trace};
step(0); document.documentElement.dataset.amllReady='true';requestAnimationFrame(frame);
