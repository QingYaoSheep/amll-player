// Development-only browser host for the pinned ORIGINAL core bundle.
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const crypto = require('node:crypto');
const {registerHooks} = require('node:module');
const {execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const legacy = path.resolve(process.argv[2] || path.join(root, '..', 'AMLL-OLD'));
const store = path.join(legacy, 'node_modules/.pnpm');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'ReferenceCaptures/amll-source-manifest.json')));
const records = manifest.dependencies.map(record => ({...record, directory:path.join(store, record.installation)}));
const core = records.find(record => record.name === '@applemusic-like-lyrics/core');
const output = path.join(root, '.build-tools/amll-reference/browser');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function entry(record, suffix) {
  const metadata = JSON.parse(fs.readFileSync(path.join(record.directory, 'package.json')));
  function condition(value) {
    if(typeof value === 'string') return value;
    for(const key of ['browser','import','default','require']) if(value?.[key]) {
      const selected = condition(value[key]); if(selected) return selected;
    }
  }
  const exported = suffix ? condition(metadata.exports?.['./'+suffix]) : condition(metadata.exports?.['.'] || metadata.exports);
  const relative = exported || (suffix ? suffix : metadata.module || metadata.main || 'index.js');
  const resolved = path.join(record.directory, relative);
  for(const candidate of [resolved,resolved+'.js',resolved+'.mjs',resolved+'.json',path.join(resolved,'index.js')]) {
    if(fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  throw Error(`Missing pinned entry ${record.name}/${relative}`);
}

async function main() {
  execFileSync(process.execPath,[path.join(__dirname,'extract-amll-reference.cjs'),legacy,'--verify'],{stdio:'inherit'});
  // Use the bundled dev tool and its exact native binary without repairing old junctions.
  process.env.NAPI_RS_NATIVE_LIBRARY_PATH = path.join(store, '@rolldown+binding-win32-x64-msvc@1.0.3/node_modules/@rolldown/binding-win32-x64-msvc/rolldown-binding.win32-x64-msvc.node');
  const compilerResolution = registerHooks({resolve(specifier,context,next) {
    if(specifier === '@rolldown/pluginutils' || specifier === '@rolldown/pluginutils/filter') {
      const suffix = specifier.endsWith('/filter') ? 'filter/index.mjs' : 'index.mjs';
      return {url:pathToFileURL(path.join(store,'@rolldown+pluginutils@1.0.1/node_modules/@rolldown/pluginutils/dist',suffix)).href,shortCircuit:true};
    }
    return next(specifier,context);
  }});
  const {rolldown} = await import(pathToFileURL(path.join(store, 'rolldown@1.0.3/node_modules/rolldown/dist/index.mjs')));
  const inputHashes = new Map();
  const build = await rolldown({
    input:path.join(__dirname, 'reference-browser/main.js'), platform:'browser',
    transform:{define:{'process.env.NODE_ENV':'"development"'}},
    plugins:[{
      name:'pinned-relocated-pnpm',
      resolveId(specifier, importer) {
        if(specifier === 'pinned-amll-core') return entry(core);
        if(specifier === 'pinned-fixture') return path.join(root, 'AMLLPlayerTests/Fixtures/amll-motion-reference.json');
        if(!importer || specifier.startsWith('.') || path.isAbsolute(specifier) || specifier.startsWith('\0')) return null;
        const parts = specifier.split('/');
        const name = specifier.startsWith('@') ? parts.slice(0,2).join('/') : parts[0];
        const suffix = parts.slice(name.startsWith('@') ? 2 : 1).join('/');
        const owner = records.filter(record => importer.startsWith(record.directory + path.sep) || importer.replaceAll('\\','/').startsWith(record.directory.replaceAll('\\','/')+'/'))
          .sort((a,b)=>b.directory.length-a.directory.length)[0];
        const link = owner?.dependencies.find(dependency => dependency.name === name);
        const dependency = records.find(record => record.installation === link?.installation);
        if(!dependency) throw Error(`Unpinned import ${specifier} in ${owner?.name || importer}`);
        return entry(dependency, suffix);
      },
      load(id) {
        if(fs.existsSync(id) && fs.statSync(id).isFile()) inputHashes.set(path.relative(legacy,id).replaceAll('\\','/'),hash(fs.readFileSync(id)));
        return null;
      }
    }]
  });
  fs.mkdirSync(output,{recursive:true});
  await build.write({dir:output,format:'esm',entryFileNames:'reference.js',sourcemap:true});
  await build.close();
  compilerResolution.deregister();
  fs.copyFileSync(path.join(core.directory,'dist/style.css'),path.join(output,'style.css'));
  for(const file of ['index.html','frame.html','host.js']) {
    fs.copyFileSync(path.join(__dirname,'reference-browser',file),path.join(output,file));
  }
  fs.writeFileSync(path.join(output,'build-manifest.json'),JSON.stringify({core:core.version,inputs:[...inputHashes].sort().map(([file,sha256])=>({file,sha256}))},null,2)+'\n');
  console.log(`Original core browser host: ${output}; ${inputHashes.size} module hashes`);
}
main().catch(error=>{console.error(error);process.exitCode=1;});
