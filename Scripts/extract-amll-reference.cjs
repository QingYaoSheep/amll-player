// Development-only: extract the locally supplied source maps without executing player code.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const legacy = path.resolve(process.argv.slice(2).find(value => !value.startsWith('--')) || path.join(root, '..', 'AMLL-OLD'));
const destination = path.join(root, '.build-tools', 'amll-reference');
const store = path.join(legacy, 'node_modules', '.pnpm');
const manifest = { schema: 2, packages: [], files: [], dependencies: [] };
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const visited = new Set();
function dependencyDirectory(directory, name) {
  for (let parent = directory; ; parent = path.dirname(parent)) {
    const candidate = path.join(parent, 'node_modules', name);
    if (fs.existsSync(path.join(candidate, 'package.json'))) return fs.realpathSync(candidate);
    // The user's copied pnpm tree retains junctions to its former workspace.
    // Resolve that exact store-relative target without repairing or changing AMLL-OLD.
    try {
      const target = fs.readlinkSync(candidate).replaceAll('\\', '/');
      const marker = '/node_modules/.pnpm/';
      const offset = target.indexOf(marker);
      if (offset >= 0) {
        const relocated = path.join(store, target.slice(offset + marker.length));
        if (fs.existsSync(path.join(relocated, 'package.json'))) return fs.realpathSync(relocated);
      }
    } catch {}
    if (parent === path.dirname(parent)) throw Error(`Missing installed dependency ${name}`);
  }
}
function pinDependencies(directory) {
  const real = fs.realpathSync(directory);
  if (visited.has(real)) return;
  visited.add(real);
  const bytes = fs.readFileSync(path.join(real, 'package.json'));
  const metadata = JSON.parse(bytes);
  const record = { name: metadata.name, version: metadata.version, license: metadata.license || null,
    installation: path.relative(store, real).split(path.sep).join('/'), sha256: hash(bytes), dependencies: [] };
  manifest.dependencies.push(record);
  const required = {...metadata.dependencies, ...metadata.peerDependencies};
  for (const name of Object.keys(required || {}).sort()) {
    let child;
    try { child = dependencyDirectory(real, name); }
    catch (error) {
      if (metadata.peerDependenciesMeta?.[name]?.optional || metadata.optionalDependencies?.[name]) continue;
      throw error;
    }
    record.dependencies.push({name, installation:path.relative(store, child).split(path.sep).join('/')});
    pinDependencies(child);
  }
}
for (const name of ['core', 'react-full']) {
  const candidates = fs.readdirSync(store).map(entry => path.join(store, entry, 'node_modules', '@applemusic-like-lyrics', name))
    .filter(entry => fs.existsSync(path.join(entry, 'package.json')));
  if (candidates.length !== 1) throw Error(`Expected one installed ${name}, found ${candidates.length}`);
  const directory = candidates[0];
  pinDependencies(directory);
  const packageBytes = fs.readFileSync(path.join(directory, 'package.json'));
  const metadata = JSON.parse(packageBytes);
  manifest.packages.push({ name: metadata.name, version: metadata.version, license: metadata.license, sha256: hash(packageBytes) });
  const mapFile = fs.readdirSync(path.join(directory, 'dist')).find(file => file.endsWith('.mjs.map'));
  const mapBytes = fs.readFileSync(path.join(directory, 'dist', mapFile));
  const map = JSON.parse(mapBytes);
  manifest.files.push({ path: `${name}/dist/${mapFile}`, sha256: hash(mapBytes) });
  map.sources.forEach((source, index) => {
    if (!source.startsWith('../src/') || !map.sourcesContent[index]) throw Error(`Missing source: ${source}`);
    const relative = `${name}/${source.slice(3)}`;
    const target = path.resolve(destination, relative);
    if (!target.startsWith(destination + path.sep)) throw Error('Invalid source path');
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, map.sourcesContent[index]);
    manifest.files.push({ path: relative, sha256: hash(Buffer.from(map.sourcesContent[index])) });
  });
  // The bundles contain SVG paths and GLSL strings absent from sourcesContent.
  for (const file of ['dist/style.css', 'package.json', `dist/${mapFile.slice(0, -4)}`]) {
    const bytes = fs.readFileSync(path.join(directory, file));
    const target = path.join(destination, name, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, bytes);
    manifest.files.push({ path: `${name}/${file}`, sha256: hash(bytes) });
  }
}
manifest.dependencies.sort((a,b) => a.installation.localeCompare(b.installation, 'en'));
for (const relative of ['packages/player/src/components/AMLLWrapper/index.tsx', 'packages/player/src/components/AMLLWrapper/index.module.css', 'pnpm-lock.yaml']) {
  manifest.files.push({ path: relative, sha256: hash(fs.readFileSync(path.join(legacy, relative))) });
}
const manifestFile = path.join(root, 'ReferenceCaptures', 'amll-source-manifest.json');
const serialized = JSON.stringify(manifest, null, 2) + '\n';
if (process.argv.includes('--verify')) {
  if (fs.readFileSync(manifestFile, 'utf8') !== serialized) throw Error('AMLL reference changed');
} else {
  fs.mkdirSync(path.dirname(manifestFile), { recursive: true });
  fs.writeFileSync(manifestFile, serialized);
}
console.log(`Verified ${manifest.files.length} reference files; extracted sources: ${destination}`);
