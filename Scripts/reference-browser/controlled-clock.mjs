// Development host only. Never bundled in the iOS application.
export class ControlledClock {
  now = 0;
  nextID = 1;
  timers = new Map();
  frames = new Map();
  animations = new Map();

  install(host) {
    this.host = host;
    host.requestAnimationFrame = callback => {
      const id = this.nextID++; this.frames.set(id, callback); return id;
    };
    host.cancelAnimationFrame = id => this.frames.delete(id);
    host.setTimeout = (callback, delay = 0, ...args) => {
      if (typeof callback !== 'function') throw Error('String timers are not supported in replay');
      const id = this.nextID++;
      this.timers.set(id, {at: this.now + Math.max(0, Number(delay) || 0), callback: () => callback(...args)});
      return id;
    };
    host.clearTimeout = id => this.timers.delete(id);
    Object.defineProperty(host.performance, 'now', {configurable: true, value: () => this.now});
    // Pinned touch velocity uses Date.now, while its inertia uses performance.now.
    if(host.Date) host.Date.now = () => 1700000000000 + this.now;
    const originalAnimate = host.Element.prototype.animate;
    const clock = this;
    host.Element.prototype.animate = function (...args) {
      return clock.track(originalAnimate.apply(this, args));
    };
  }

  track(animation) {
    if (this.animations.has(animation)) return animation;
    const native = Object.fromEntries(['play', 'pause', 'cancel', 'finish', 'reverse', 'updatePlaybackRate']
      .filter(key => typeof animation[key] === 'function').map(key => [key, animation[key].bind(animation)]));
    const state = {running: animation.playState === 'running', cancelled: false, finished: false};
    const initialTime = animation.currentTime;
    native.pause(); animation.currentTime = typeof initialTime === 'number' ? initialTime : 0;
    this.animations.set(animation, state);
    animation.play = () => {
      if (state.cancelled) this.animations.set(animation, state);
      state.cancelled = false;
      const end = animation.effect?.getComputedTiming().endTime ?? Infinity;
      const rate = animation.playbackRate;
      if (animation.currentTime === null || (rate >= 0 && animation.currentTime >= end)) animation.currentTime = 0;
      else if (rate < 0 && animation.currentTime <= 0 && Number.isFinite(end)) animation.currentTime = end;
      state.running = true; state.finished = false;
      native.pause();
    };
    animation.pause = () => { state.running = false; native.pause(); };
    animation.cancel = () => {
      state.running = false; state.cancelled = true; native.cancel(); this.animations.delete(animation);
    };
    animation.reverse = () => { animation.playbackRate = -(animation.playbackRate || 1); animation.play(); };
    animation.updatePlaybackRate = rate => { animation.playbackRate = rate; };
    animation.finish = () => {
      native.finish(); state.running = false; state.finished = true; native.pause();
    };
    return animation;
  }

  capture(root) {
    // Force CSS transitions to exist before discovering and pausing them.
    root.getBoundingClientRect();
    for (const animation of root.getAnimations({subtree: true})) this.track(animation);
  }

  advance(milliseconds) {
    if (!Number.isFinite(milliseconds) || milliseconds < 0) throw Error('Replay delta must be finite and nonnegative');
    const target = this.now + milliseconds;
    let count = 0;
    while (true) {
      const next = [...this.timers].filter(([, timer]) => timer.at <= target)
        .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!next) break;
      if (++count > 10000) throw Error('Replay timer loop exceeded bound');
      this.sampleAnimations(next[1].at - this.now); this.now = next[1].at;
      this.timers.delete(next[0]); next[1].callback();
    }
    this.sampleAnimations(target - this.now); this.now = target;
    const callbacks = [...this.frames.values()]; this.frames.clear();
    callbacks.forEach(callback => callback(this.now));
  }

  sampleAnimations(delta) {
    for (const [animation, state] of [...this.animations]) {
      if (!state.running || state.cancelled) continue;
      const rate = animation.playbackRate;
      const end = animation.effect?.getComputedTiming().endTime ?? Infinity;
      const value = Number(animation.currentTime ?? 0) + delta * rate;
      animation.currentTime = rate < 0 ? Math.max(0, value) : Math.min(end, value);
      if ((rate > 0 && value >= end) || (rate < 0 && value <= 0)) {
        state.running = false; state.finished = true;
        // Pinned core uses onfinish to pause its emphasis layers.
        animation.dispatchEvent(new Event('finish'));
      }
    }
  }
}
