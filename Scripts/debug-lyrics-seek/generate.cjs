const fs = require('node:fs');
const inputs = ['AMLLVisualActivityTests','AMLLSeekMotionTests'];
let tests = '', cases = [];
for (const name of inputs) {
 let source = fs.readFileSync('AMLLPlayerTests/'+name+'.swift','utf8').replace(/@testable import AMLLPlayer/g,'').replace(/import UIKit/g,'');
 // Exclude only actual UIKit canvas tests from the Foundation CLI. CI runs them in the real app.
 for (;;) {
  const found = /    @MainActor\s+func test/.exec(source);
  if (!found) break;
  const body = source.indexOf('{', found.index); let end = body + 1, depth = 1;
  while (depth && end < source.length) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
  source = source.slice(0,found.index)+source.slice(end);
 }
 tests += source+'\n';
 const methods = [...source.matchAll(/    func (test\w+)\(/g)].map(x=>x[1]);
 cases.push('testCase(['+methods.map(m=>'("'+m+'", '+name+'.'+m+')').join(',')+'])');
}
fs.writeFileSync('build/seek-loop/Tests.swift',tests);
fs.writeFileSync('build/seek-loop/main.swift','import XCTest\nXCTMain(['+cases.join(',')+'])\n');
