// Tiny static server for the audit page: node tools/bidi-audit/serve.js [port]
'use strict';
const http = require('http'), fs = require('fs'), path = require('path');
const port = +process.argv[2] || 5177;
http.createServer((req, res) => {
  // POST /results saves the page's measured RESULTS for a precomputed build.
  // POST /save?name=x.html writes a generated frame page under shots/.
  if (req.method === 'POST' && req.url.startsWith('/save?name=')) {
    const name = path.basename(decodeURIComponent(req.url.slice('/save?name='.length)));
    let body = '';
    req.on('data', d => { body += d; });
    req.on('end', () => {
      fs.mkdirSync(path.join(__dirname, 'shots'), { recursive: true });
      fs.writeFileSync(path.join(__dirname, 'shots', name), body);
      res.end('ok');
    });
    return;
  }
  if (req.method === 'POST' && req.url === '/results') {
    let body = '';
    req.on('data', d => { body += d; });
    req.on('end', () => { fs.writeFileSync(path.join(__dirname, 'results.json'), body); res.end('ok'); });
    return;
  }
  const name = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'report.html';
  const file = path.join(__dirname, path.basename(name));
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream' });
    res.end(buf);
  });
}).listen(port, '127.0.0.1', () => console.log('bidi-audit on http://127.0.0.1:' + port));
