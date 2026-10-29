// Builds report.html: embeds the upstream and fork payloads (core inlined, same
// way tools/build-payload.ps1 does) plus the cases into template.html.
// Usage: node tools/bidi-audit/build.js
'use strict';
const fs = require('fs');
const path = require('path');
const here = __dirname;
const repo = path.join(here, '..', '..');

function assemble(corePath, payPath) {
  let core = fs.readFileSync(corePath, 'utf8').replace(/\r\n/g, '\n');
  const g = core.indexOf('if (typeof module !==');
  if (g >= 0) core = core.slice(0, g).trimEnd() + '\n';
  const pay = fs.readFileSync(payPath, 'utf8').replace(/\r\n/g, '\n');
  return pay.replace('/*__RTL_CORE__*/', () => core.trimEnd());
}

const payloads = {
  upstream: assemble(path.join(here, 'upstream-core.js'), path.join(here, 'upstream-payload.js')),
  installed: assemble(path.join(here, 'installed-core.js'), path.join(here, 'installed-payload.js')),
  fork: assemble(path.join(repo, 'src', 'rtl-core.js'), path.join(repo, 'src', 'rtl-payload.js'))
};
const cases = fs.readFileSync(path.join(here, 'cases.js'), 'utf8');
let data = 'window.PAYLOADS = ' + JSON.stringify(payloads).replace(/<\//g, '<\\/') + ';\n' + cases.replace(/<\/script/gi, '<\\/script');
const pre = process.argv[2];
if (pre) data += '\nwindow.PRECOMPUTED = ' + fs.readFileSync(pre, 'utf8') + ';\n';
const tpl = fs.readFileSync(path.join(here, 'template.html'), 'utf8');
const out = path.join(here, pre ? 'report-static.html' : 'report.html');
let page = tpl.replace('/*__DATA__*/', () => data);
// The artifact host supplies its own document skeleton.
// Only the outer wrapper lines go; frameDoc's own srcdoc skeleton must stay.
if (pre) {
  const head = page.indexOf('<title>');
  page = page.slice(head)
    .replace('</head>\n<body>\n', '')
    .replace(/<\/body>\s*<\/html>\s*$/, '\n');
}
fs.writeFileSync(out, page);
console.log('wrote', out);
