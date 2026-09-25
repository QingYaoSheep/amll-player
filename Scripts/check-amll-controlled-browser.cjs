// Executes the pinned DOM renderer in installed headless Edge using CDP.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {spawn} = require('node:child_process');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../.build-tools/amll-reference/browser');
const profile = fs.mkdtempSync(path.resolve(__dirname, '../.build-tools/edge-replay-'));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const server = http.createServer((req, res) => {
  const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) { res.writeHead(404);res.end();return; }
  res.setHeader('Content-Type', /\.m?js$/.test(file) ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html');
  res.end(fs.readFileSync(file));
});
let browser, socket;
async function main() {
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  browser = spawn(process.env.AMLL_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    ['--headless=new','--no-first-run','--no-default-browser-check','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],
    {windowsHide:true,stdio:'ignore'});
  browser.on('error', error => { console.error(error.message); process.exitCode=1; });
  const active = path.join(profile,'DevToolsActivePort');
  for(let i=0;i<100&&!fs.existsSync(active);i++) await delay(100);
  const port=fs.readFileSync(active,'utf8').split('\n')[0];
  const tabs=await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  socket=new WebSocket(tabs.find(tab=>tab.type==='page').webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;});
  let serial=0;const pending=new Map();
  socket.onmessage=event=>{const result=JSON.parse(event.data);if(result.id){pending.get(result.id)?.(result);pending.delete(result.id);}};
  const send=(method,params={})=>new Promise((resolve,reject)=>{
    const id=++serial;const timeout=setTimeout(()=>{pending.delete(id);reject(Error(`CDP timeout: ${method}`));},15000);
    pending.set(id,result=>{clearTimeout(timeout);result.error?reject(Error(JSON.stringify(result.error))):resolve(result.result);});
    socket.send(JSON.stringify({id,method,params}));
  });
  const evaluate=async expression=>{
    const value=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});
    if(value.exceptionDetails)throw Error(JSON.stringify(value.exceptionDetails));
    return value.result.value;
  };
  await send('Page.enable');
  await send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/index.html?clock=controlled`});
  for(let i=0;i<100;i++) {
    if(await evaluate('!!window.frames[0]?.amllReference')) break;
    await delay(100);
  }
  assert.equal(await evaluate('!!window.frames[0]?.amllReference'),true,'reference initialized');
  if (process.env.AMLL_ROMANIZATION_PROBE === '1') {
    const probe = require('./probe-amll-romanization.cjs');
    const fixture = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../AMLLPlayerTests/Fixtures/romanization-containers.json'), 'utf8'));
    const results = await evaluate('(' + probe.toString() + ')(window.frames[0].amllReference,' + JSON.stringify(fixture) + ')');
    assert.equal(results.length, fixture.lines.length);
    for (const row of results) for (const word of row) {
      assert.equal(word.fontSize, '16px');
      assert.equal(word.lineHeight, '16px');
      assert.equal(word.paddingInlineEnd, '4.8px');
      assert.ok(word.width > 0);
    }
    fs.writeFileSync(path.resolve(root, '../romanization-probe.json'), JSON.stringify(results, null, 2));
    console.log('Pinned original romanization: 7 multilingual cases passed');
    return;
  }
  const expression='JSON.stringify(window.frames[0].amllReference.capture(true))';
  const frozen=await evaluate(expression);await delay(300);
  assert.equal(await evaluate(expression),frozen,'wall time must not change frozen geometry or animations');
  await evaluate('document.querySelector("#play").click(); window.frames[0].amllReference.step(1/60);');
  const after=await evaluate('({time:window.frames[0].amllReference.clock.now,position:window.frames[0].amllReference.capture().position})');
  assert.ok(Math.abs(after.time-1000/60)<1e-7);assert.ok(Math.abs(after.position-(1+1/60))<1e-7);
  await evaluate('document.querySelector("#play").click(); window.frames[0].amllReference.step(1/120);');
  assert.equal(await evaluate('window.frames[0].amllReference.capture().position'),after.position,'pause holds song time');
  const scenario=`(async()=>{
    const r=window.frames[0].amllReference;const samples=[];
    const target=r.player.getElement();
    const touch=(type,y)=>{
      const w=window.frames[0];const value=new w.Touch({identifier:1,target,screenX:100,screenY:y,clientX:100,clientY:y});
      target.dispatchEvent(new w.TouchEvent(type,{touches:type==='touchend'?[]:[value],changedTouches:[value],bubbles:true,cancelable:true}));
    };
    document.querySelector('#play').click();
    for(let i=0;i<180;i++) {
      if(i===30||i===60) document.querySelector('#play').click();
      if(i===90) await r.step(0,5,true);
      if(i===100) touch('touchstart',250);
      if(i===101) touch('touchmove',200);
      if(i===102) touch('touchend',200);
      if(i===150) r.player.resetScroll();
      await r.step(i%3===0?1/120:1/60);samples.push(r.capture(true));
    }
    return JSON.stringify(samples);
  })()`;
  const restart=async()=>{
    await send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/index.html?clock=controlled&run=${Date.now()}`});
    await delay(200);
    for(let i=0;i<100;i++) {if(await evaluate('!!window.frames[0]?.amllReference'))return;await delay(100);}
    throw Error('Replay reload failed');
  };
  await restart();const first=await evaluate(scenario);
  const frames=JSON.parse(first);
  assert.ok(frames.some(frame=>frame.groups.some(group=>group.lines.some(line=>line.rect.width>0&&line.text.length>0))), 'actual lyric glyph elements must be present');
  assert.ok(frames.some(frame=>frame.animations.length>0), 'actual WAAPI animations must be sampled');
  await restart();const second=await evaluate(scenario);
  if(second!==first) {
    fs.writeFileSync(path.join(profile,'first.json'),first);fs.writeFileSync(path.join(profile,'second.json'),second);
    throw Error(`Repeated replay mismatch; inspect ${profile}`);
  }
  await restart();
  const shared=await evaluate('window.frames[0].amllReference.replayScenario().then(JSON.stringify)');
  const sharedFrames=JSON.parse(shared).frames;
  assert.equal(sharedFrames.length,480);
  assert.equal(sharedFrames[120].position,5);
  assert.equal(sharedFrames[179].position,5);
  await restart();
  assert.equal(await evaluate('window.frames[0].amllReference.replayScenario().then(JSON.stringify)'),shared,
    'shared native/browser scenario must replay identically after reload');
  await evaluate(`(async()=>{
    const r=window.frames[0].amllReference;
    r.player.setLyricLines([{startTime:1000,endTime:7000,isBG:false,isDuet:false,translatedLyric:'Translation',romanLyric:'',
      words:[{word:'long ',startTime:1000,endTime:4000,romanWord:''},{word:'note',startTime:4000,endTime:7000,romanWord:''}]}],1000);
    r.player.resume();await r.step(0,1,true);
    for(let i=0;i<60;i++)await r.step(1/60);
  })()`);
  assert.ok(await evaluate('window.frames[0].amllReference.capture().groups.some(g=>g.lines.some(l=>l.words.length>0))'), 'timed words must actually render');
  const wordsFrozen=await evaluate(expression);await delay(200);
  assert.equal(await evaluate(expression),wordsFrozen,'word masks and emphasis must freeze with wall time');
  await send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/visual-diff.html`});
  for(let i=0;i<100;i++) {
    if(await evaluate('!!document.querySelector("#compare")?.onclick'))break;
    await delay(50);
  }
  const diffResult=await evaluate(`(async()=>{
    const metadata={lyricSHA256:'a'.repeat(64),artworkSHA256:'b'.repeat(64),scenarioSHA256:'c'.repeat(64),
      configurationSHA256:'d'.repeat(64),width:2,height:1,displayScale:1,frame:0,font:'fixture',coordinateSpace:'content-physical-pixels'};
    function assign(id,file){const files=new DataTransfer();files.items.add(file);document.getElementById(id).files=files.files;}
    for(const [id,x] of [['reference',0],['actual',1]]) {
      const canvas=document.createElement('canvas');canvas.width=2;canvas.height=1;
      canvas.getContext('2d').fillRect(x,0,1,1);
      const blob=await new Promise(resolve=>canvas.toBlob(resolve));assign(id,new File([blob],id+'.png',{type:'image/png'}));
      assign(id+'Meta',new File([JSON.stringify(metadata)],id+'.json',{type:'application/json'}));
    }
    await document.getElementById('compare').onclick();
    return {report:JSON.parse(document.getElementById('status').textContent),width:document.getElementById('overlay').width};
  })()`);
  assert.equal(diffResult.report.changedPixels,2);assert.equal(diffResult.width,2);
  console.log('Pinned browser: frozen wall clock, 60/120 Hz steps, paused song clock passed.');
}
main().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>{socket?.close();browser?.kill();server.close();});

