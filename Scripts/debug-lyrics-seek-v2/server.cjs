const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
http.createServer((req, res) => {
  if (!/^\/seek-markers\.(mp3|m4a|flac)$/.test(req.url)) { res.writeHead(404).end(); return; }
  const file = path.join(process.argv[2], req.url.slice(1));
  const size = fs.statSync(file).size;
  let start = 0, end = size - 1;
  const range = req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
  if (range) { start = Number(range[1]); end = range[2] ? Math.min(end, Number(range[2])) : end; }
  if (start >= size || start > end) { res.writeHead(416, {'Content-Range': 'bytes */' + size}).end(); return; }
  const headers = {'Accept-Ranges':'bytes', 'Content-Length': end - start + 1,
    'Content-Type': file.endsWith('.flac') ? 'audio/flac' : file.endsWith('.mp3') ? 'audio/mpeg' : 'audio/mp4'};
  if (range) headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + size;
  res.writeHead(range ? 206 : 200, headers);
  if (req.method === 'HEAD') res.end(); else fs.createReadStream(file, {start, end}).pipe(res);
}).listen(18083, '127.0.0.1');
