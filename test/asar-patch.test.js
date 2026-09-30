'use strict';

// Direct ASAR patcher (src/asar-patch.cjs): archive round trip, payload placement,
// integrity records, failure modes, and the copy embedded in patch.ps1.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const asar = require('../src/asar-patch.cjs');

const HELPER = path.join(__dirname, '..', 'src', 'asar-patch.cjs');
const RENDERER = '// --- CLAUDE RTL PATCH START ---\n;globalThis.__rtl = 1;\n// --- CLAUDE RTL PATCH END ---';
const MAIN = '// --- CLAUDE RTL MAIN PATCH START ---\n;globalThis.__rtlMain = 1;\n// --- CLAUDE RTL MAIN PATCH END ---';

const SOURCES = {
    'package.json': JSON.stringify({ main: './.vite/build/index.pre.js' }),
    '.vite/build/index.pre.js': '"use strict";\nrequire("./index.js");',
    '.vite/build/index.js': 'module.exports = "main bundle";',
    '.vite/build/mainWindow.js': "'use strict';\nconst s = '\u05e9\u05dc\u05d5\u05dd';",
    '.vite/build/sloppy.js': 'var x = this;',
    '.vite/build/mcp-runtime/nodeHost.js': 'const host = 1;',
    '.vite/build/bom.js': '\ufeffvar bom = 1;',
    '.vite/build/latin1.js': Buffer.from([0x76, 0x61, 0x72, 0x20, 0xe9, 0x3b]), // "var \xe9;"
    '.vite/build/empty.js': '',
    'assets/logo.bin': Buffer.from([0, 1, 2, 255, 254]),
    'assets/copy.bin': Buffer.from([0, 1, 2, 255, 254])
};

function tmpDir(t) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'asar-patch-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    return dir;
}

// Builds a small archive shaped like Claude's: integrity records with a tiny block
// size (so multi-block files occur), an unpacked native module, a link, an
// executable flag, and two entries sharing one data range.
function buildArchive(file, edit) {
    const header = { files: {} };
    const chunks = [];
    let offset = 0;
    for (const [key, content] of Object.entries(SOURCES)) {
        const parts = key.split('/');
        let dir = header;
        for (const p of parts.slice(0, -1)) dir = (dir.files[p] = dir.files[p] || { files: {} });
        const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
        if (key === 'assets/copy.bin') { // dedupe onto logo.bin's range
            dir.files[parts.at(-1)] = structuredClone(header.files.assets.files['logo.bin']);
            continue;
        }
        dir.files[parts.at(-1)] = { size: bytes.length, offset: String(offset), integrity: asar.integrityOf(bytes, 16) };
        chunks.push(bytes);
        offset += bytes.length;
    }
    header.files.assets.files['logo.bin'].executable = true;
    header.files['native.node'] = { size: 1234, unpacked: true, integrity: asar.integrityOf(Buffer.from('native'), 16) };
    header.files['link.bin'] = { link: 'assets/logo.bin' };
    if (edit) edit(header);
    fs.writeFileSync(file, Buffer.concat([asar.encodeHeader(header), ...chunks]));
    return header;
}

function open(file) {
    const fd = fs.openSync(file, 'r');
    try {
        const archive = asar.readArchive(fd);
        asar.verifyArchive(fd, archive);
        const raw = fs.readFileSync(file);
        const content = key => {
            const f = archive.files.find(x => x.key === key);
            return raw.subarray(archive.dataStart + f.offset, archive.dataStart + f.offset + f.size);
        };
        return { ...archive, content };
    } finally { fs.closeSync(fd); }
}

test('injects renderer and main payloads, leaves everything else byte-identical', t => {
    const dir = tmpDir(t);
    const src = path.join(dir, 'app.asar'), dst = path.join(dir, 'app.asar.new');
    const header = buildArchive(src);
    const report = asar.patchArchive(src, dst, RENDERER, MAIN);

    assert.strictEqual(report.ok, true);
    assert.strictEqual(report.mainEntry, '.vite/build/index.pre.js');
    assert.strictEqual(report.main, 'injected');
    assert.deepStrictEqual(report.injected.sort(), ['.vite/build/bom.js', '.vite/build/empty.js',
        '.vite/build/mainWindow.js', '.vite/build/sloppy.js']);
    assert.deepStrictEqual(report.skipped.sort(), ['.vite/build/index.js', '.vite/build/mcp-runtime/nodeHost.js']);
    assert.deepStrictEqual(report.notUtf8, ['.vite/build/latin1.js']);

    const before = open(src), after = open(dst);
    // "use strict" stays first (#36); sloppy files get a plain prepend.
    assert.match(after.content('.vite/build/index.pre.js').toString(), /^"use strict";\n\/\/ --- CLAUDE RTL MAIN PATCH START/);
    assert.match(after.content('.vite/build/mainWindow.js').toString(), /^'use strict';\n\/\/ --- CLAUDE RTL PATCH START[\s\S]*\u05e9\u05dc\u05d5\u05dd';$/);
    assert.ok(after.content('.vite/build/sloppy.js').toString().startsWith(RENDERER + '\nvar x = this;'));
    assert.strictEqual(after.content('.vite/build/bom.js').toString(), RENDERER + '\nvar bom = 1;');

    for (const key of ['package.json', '.vite/build/index.js', '.vite/build/mcp-runtime/nodeHost.js',
        '.vite/build/latin1.js', 'assets/logo.bin', 'assets/copy.bin']) {
        assert.ok(after.content(key).equals(before.content(key)), key);
    }
    // Header-only records survive verbatim; the dedupe is kept.
    assert.deepStrictEqual(after.header.files['native.node'], header.files['native.node']);
    assert.deepStrictEqual(after.header.files['link.bin'], header.files['link.bin']);
    assert.deepStrictEqual(after.unpacked, ['native.node']);
    assert.strictEqual(after.header.files.assets.files['logo.bin'].executable, true);
    assert.strictEqual(after.header.files.assets.files['copy.bin'].offset, after.header.files.assets.files['logo.bin'].offset);
    // Edited files keep the source block size.
    assert.strictEqual(after.header.files['.vite'].files.build.files['mainWindow.js'].integrity.blockSize, 16);
});

test('re-running on a patched archive changes nothing', t => {
    const dir = tmpDir(t);
    const a = path.join(dir, 'a.asar'), b = path.join(dir, 'b.asar'), c = path.join(dir, 'c.asar');
    buildArchive(a);
    asar.patchArchive(a, b, RENDERER, MAIN);
    const again = asar.patchArchive(b, c, RENDERER, MAIN);
    assert.strictEqual(again.main, 'already');
    assert.strictEqual(again.injected.length, 0);
    assert.strictEqual(again.alreadyPatched.length, 4);
    assert.ok(fs.readFileSync(b).equals(fs.readFileSync(c)));
});

test('fails closed: corrupt source, bad main syntax, existing destination', t => {
    const dir = tmpDir(t);
    const src = path.join(dir, 'app.asar'), dst = path.join(dir, 'out.asar');
    buildArchive(src);

    assert.throws(() => asar.patchArchive(src, dst, RENDERER, 'if ('), /fails node --check/);
    assert.strictEqual(fs.existsSync(dst), false);

    fs.writeFileSync(dst, 'keep');
    assert.throws(() => asar.patchArchive(src, dst, RENDERER, MAIN), /EEXIST/);
    assert.strictEqual(fs.readFileSync(dst, 'utf8'), 'keep');
    fs.unlinkSync(dst);

    const bytes = fs.readFileSync(src);
    bytes[bytes.length - 1] ^= 0xff;
    fs.writeFileSync(src, bytes);
    assert.throws(() => asar.patchArchive(src, dst, RENDERER, MAIN), /Integrity mismatch/);
    assert.strictEqual(fs.existsSync(dst), false);
});

test('accepts the @electron/asar 3.x trailing empty block on exact-multiple sizes', t => {
    const dir = tmpDir(t);
    const src = path.join(dir, 'app.asar'), dst = path.join(dir, 'out.asar');
    const crypto = require('node:crypto');
    const empty = crypto.createHash('sha256').update(Buffer.alloc(0)).digest('hex');
    buildArchive(src, h => {
        const ig = h.files['.vite'].files.build.files['empty.js'].integrity;
        assert.strictEqual(ig.blocks.length, 1); // size 0: single empty block, unchanged
        const logo = h.files.assets.files['logo.bin'];
        logo.integrity = asar.integrityOf(Buffer.from([0, 1, 2, 255, 254]), 5); // size 5 = 1 x 5
        logo.integrity.blocks.push(empty);
        h.files.assets.files['copy.bin'] = structuredClone(logo);
    });
    assert.doesNotThrow(() => asar.patchArchive(src, dst, RENDERER, MAIN));
});

test('rejects malformed headers', t => {
    const dir = tmpDir(t);
    const cases = [
        [h => { h.files.assets.files['logo.bin'].offset = '999999'; }, /out of bounds/],
        [h => { h.files.assets.files['logo.bin'].offset = 7; }, /Invalid offset/],
        [h => { h.files.assets.files['logo.bin'].size = -1; }, /Invalid size/],
        [h => { h.files['package.json'].integrity.algorithm = 'MD5'; }, /Unsupported integrity/],
        [h => { h.files['package.json'].offset = '1'; }, /Overlapping/],
        [h => { h.files.bad = { files: [] }; }, /Invalid ASAR directory/]
    ];
    cases.forEach(([edit, re], i) => {
        const src = path.join(dir, i + '.asar'), dst = path.join(dir, i + '.out');
        buildArchive(src, edit);
        assert.throws(() => asar.patchArchive(src, dst, RENDERER, MAIN), re, String(re));
        assert.strictEqual(fs.existsSync(dst), false);
    });
    const junk = path.join(dir, 'junk.asar');
    fs.writeFileSync(junk, Buffer.alloc(64, 7));
    assert.throws(() => asar.patchArchive(junk, path.join(dir, 'junk.out'), RENDERER, MAIN), /Invalid ASAR header/);
});

test('CLI prints one ASCII JSON line for success and failure', t => {
    const dir = tmpDir(t);
    const src = path.join(dir, 'app.asar');
    buildArchive(src);
    const r = path.join(dir, 'r.js'), m = path.join(dir, 'm.js');
    fs.writeFileSync(r, RENDERER);
    fs.writeFileSync(m, MAIN);

    const ok = spawnSync(process.execPath, [HELPER, src, path.join(dir, 'out.asar'), r, m], { encoding: 'utf8' });
    assert.strictEqual(ok.status, 0, ok.stderr);
    assert.strictEqual(ok.stdout.trim().split('\n').length, 1);
    assert.strictEqual(JSON.parse(ok.stdout).main, 'injected');

    const bad = spawnSync(process.execPath, [HELPER, path.join(dir, 'missing.asar'), path.join(dir, 'x.asar'), r, m], { encoding: 'utf8' });
    assert.strictEqual(bad.status, 1);
    const err = JSON.parse(bad.stdout);
    assert.strictEqual(err.ok, false);
    assert.match(err.error, /ENOENT/);
    assert.match(bad.stdout, /^[\x00-\x7f]*$/);
});

test('helper source is ASCII and embedded verbatim in patch.ps1', () => {
    const src = fs.readFileSync(HELPER, 'utf8').replace(/\r\n/g, '\n').trimEnd();
    assert.match(src, /^[\x00-\x7f]*$/, 'PowerShell 5.1 reads patch.ps1 as ANSI');
    assert.doesNotMatch(src, /^'@/m, 'would terminate the here-string');
    const patch = fs.readFileSync(path.join(__dirname, '..', 'patch.ps1'), 'utf8').replace(/\r\n/g, '\n');
    const m = /\/\/ --- CLAUDE RTL ASAR HELPER START ---\n([\s\S]*?)\n\/\/ --- CLAUDE RTL ASAR HELPER END ---/.exec(patch);
    assert.ok(m, 'helper markers present in patch.ps1');
    assert.strictEqual(m[1], src, 'run `npm run build` after editing src/asar-patch.cjs');
});
