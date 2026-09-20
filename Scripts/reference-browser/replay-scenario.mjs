// Same schema and beginning-of-frame event ordering as AMLLReplayCursor.
export function replaySteps(scenario) {
  const kinds = new Set(['play','pause','seek','beginBrowsing','browseBy','endBrowsing','resumeFollowing']);
  if(scenario.schema !== 1 || !Number.isFinite(scenario.initialPosition) || scenario.initialPosition < 0 ||
     !Array.isArray(scenario.frameDeltas) || !scenario.frameDeltas.length ||
     scenario.frameDeltas.some(dt=>!Number.isFinite(dt)||dt<0) || !Array.isArray(scenario.events) ||
     scenario.events.some((e,i)=>!Number.isInteger(e.frame)||e.frame<0||e.frame>=scenario.frameDeltas.length||
       !kinds.has(e.kind)||(i>0&&e.frame<scenario.events[i-1].frame)||
       (e.value!=null&&!Number.isFinite(e.value))||
       (['seek','browseBy','endBrowsing'].includes(e.kind)&&e.value==null)||
       (e.kind==='seek'&&e.value<0))) throw Error('Invalid replay scenario');
  let position=scenario.initialPosition, playing=scenario.initiallyPlaying, revision=0;
  return scenario.frameDeltas.map((delta,frame)=>{
    const events=scenario.events.filter(event=>event.frame===frame);
    let seeking=false;
    for(const event of events) {
      if(event.kind==='play')playing=true;
      if(event.kind==='pause')playing=false;
      if(event.kind==='seek'){position=event.value;seeking=true;revision++;}
    }
    const startPosition=position;
    if(playing)position+=delta;
    return {frame,delta,startPosition,position,playing,seeking,revision,events};
  });
}
