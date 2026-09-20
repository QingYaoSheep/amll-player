import {test} from 'node:test';
import assert from 'node:assert/strict';
import {ControlledClock} from './reference-browser/controlled-clock.mjs';

class Animation extends EventTarget {
  currentTime=0; playbackRate=1; playState='running';
  effect={getComputedTiming:()=>({endTime:100})};
  pause(){this.playState='paused';}
  cancel(){this.currentTime=null;this.playState='idle';}
  play(){this.playState='running';}
  finish(){this.currentTime=100;}
}
test('pause, resume, rate changes, reverse and cancellation are controlled',()=>{
  const clock=new ControlledClock(), animation=clock.track(new Animation());
  clock.advance(25);assert.equal(animation.currentTime,25);
  animation.pause();clock.advance(25);assert.equal(animation.currentTime,25);
  animation.play();animation.updatePlaybackRate(2);clock.advance(10);assert.equal(animation.currentTime,45);
  animation.reverse();clock.advance(10);assert.equal(animation.currentTime,25);
  animation.cancel();clock.advance(10);assert.equal(animation.currentTime,null);
  assert.equal(clock.animations.size,0);
});
test('finish event happens once and reversing can resume from the end',()=>{
  const clock=new ControlledClock(), animation=clock.track(new Animation());let finished=0;
  animation.addEventListener('finish',()=>finished++);
  clock.advance(150);clock.advance(50);assert.equal(finished,1);assert.equal(animation.currentTime,100);
  animation.reverse();clock.advance(25);assert.equal(animation.currentTime,75);
});
test('timer order, nested RAF and cancellation do not depend on wall time',()=>{
  const host={performance:{},Element:class {animate(){return new Animation();}}};
  const clock=new ControlledClock();clock.install(host);const events=[];
  host.setTimeout(()=>events.push(['timer',host.performance.now()]),20);
  const cancelled=host.setTimeout(()=>assert.fail('cancelled timer'),10);host.clearTimeout(cancelled);
  host.requestAnimationFrame(time=>{events.push(['frame',time]);host.requestAnimationFrame(t=>events.push(['next',t]));});
  clock.advance(30);assert.deepEqual(events,[['timer',20],['frame',30]]);
  clock.advance(10);assert.deepEqual(events.at(-1),['next',40]);
  assert.throws(()=>clock.advance(-1));
});
