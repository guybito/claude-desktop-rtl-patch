'use strict';

// Direct ASAR patcher, embedded in patch.ps1 (tools/build-payload.ps1) and run by
// the elevated installer with the system node.exe. Only the JS entries that get
// the RTL payload are rewritten; every other packed file is streamed across
// unchanged -- no extraction, no npm, no network. Unpacked entries (native
// modules living in app.asar.unpacked) keep their header records verbatim, so
// they stay external, unlike an extract + repack round trip.
//
// Integrity records are verified on the source, recomputed for edited files and
// re-verified on the finished output. The destination is created exclusively and
// deleted on any failure, so the caller either gets a verified archive or nothing.
//
// KEEP THIS FILE ASCII-ONLY: it is embedded in patch.ps1, which PowerShell 5.1
// reads with the ANSI code page.

const fs = require('node:fs');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const RENDERER_MARKER = 'CLAUDE RTL PATCH START';
const MAIN_MARKER = 'CLAUDE RTL MAIN PATCH START';
const BUILD_DIR = '.vite/build/';
const DEFAULT_MAIN = '.vite/build/index.pre.js';
// Node-side bundles with no DOM: the renderer payload must never reach them (#14).
const SKIP = new Set(['index.js', 'directMcpHost.js', 'nodeHost.js',
    'shellPathWorker.js', 'transcriptSearchWorker.js']);
const MAX_HEADER = 10 * 1024 * 1024; // same cap as Compute-AsarHash in patch.ps1
const CHUNK = 4 * 1024 * 1024;
// A leading "use strict"; must stay the first statement (#36).
const STRICT_RE = /^\s*("use strict"|'use strict')\s*;/;

const sha256 = buf => crypto.createHash('sha256').update(buf).digest('hex');
const align4 = n => Math.ceil(n / 4) * 4;
const leaf = key => key.slice(key.lastIndexOf('/') + 1);

function readAt(fd, length, position) {
    const buf = Buffer.alloc(length);
    for (let done = 0; done < length;) {
        const n = fs.readSync(fd, buf, done, length - done, position + done);
        if (n === 0) throw new Error('Unexpected end of archive');
        done += n;
    }
    return buf;
}

function writeAll(fd, buf) {
    for (let done = 0; done < buf.length;) {
        const n = fs.writeSync(fd, buf, done, buf.length - done);
        if (n === 0) throw new Error('Short write');
        done += n;
    }
}

// Pickle layout: [4][headerSize][headerSize - 4][jsonSize][json, padded to 4].
function readArchive(fd) {
    const size = fs.fstatSync(fd).size;
    if (size < 16) throw new Error('Not an ASAR archive');
    const pre = readAt(fd, 16, 0);
    const headerSize = pre.readUInt32LE(4);
    const jsonSize = pre.readUInt32LE(12);
    if (pre.readUInt32LE(0) !== 4 || jsonSize === 0 || jsonSize > MAX_HEADER ||
        headerSize !== 8 + align4(jsonSize) || pre.readUInt32LE(8) !== headerSize - 4 ||
        8 + headerSize > size) {
        throw new Error('Invalid ASAR header');
    }
    const header = JSON.parse(readAt(fd, jsonSize, 16).toString('utf8'));
    const dataStart = 8 + headerSize;
    const files = [];   // packed entries only
    const unpacked = [];

    (function walk(dir, prefix, depth) {
        if (depth > 64 || !dir || typeof dir.files !== 'object' || dir.files === null || Array.isArray(dir.files)) {
            throw new Error('Invalid ASAR directory: ' + (prefix || '/'));
        }
        for (const name of Object.keys(dir.files)) {
            const entry = dir.files[name];
            const key = prefix + name;
            if (!name || name.includes('/') || !entry || typeof entry !== 'object') {
                throw new Error('Invalid ASAR entry: ' + key);
            }
            if ('files' in entry) { walk(entry, key + '/', depth + 1); continue; }
            if ('link' in entry) continue; // header-only; kept verbatim
            if (!Number.isSafeInteger(entry.size) || entry.size < 0) throw new Error('Invalid size: ' + key);
            if (entry.unpacked) { unpacked.push(key); continue; }
            if (typeof entry.offset !== 'string' || !/^\d+$/.test(entry.offset)) throw new Error('Invalid offset: ' + key);
            const offset = Number(entry.offset);
            if (!Number.isSafeInteger(offset) || dataStart + offset + entry.size > size) {
                throw new Error('Entry out of bounds: ' + key);
            }
            const ig = entry.integrity;
            if (ig !== undefined && (!ig || ig.algorithm !== 'SHA256' || typeof ig.hash !== 'string' ||
                !Number.isSafeInteger(ig.blockSize) || ig.blockSize < 1 || ig.blockSize > 64 * 1024 * 1024 ||
                !Array.isArray(ig.blocks))) {
                throw new Error('Unsupported integrity record: ' + key);
            }
            files.push({ key, entry, offset, size: entry.size });
        }
    })(header, '', 0);

    // Ranges may repeat (deduplicated content) but must not partially overlap.
    const byOffset = files.slice().sort((a, b) => a.offset - b.offset || a.size - b.size);
    for (let i = 1; i < byOffset.length; i++) {
        const prev = byOffset[i - 1], cur = byOffset[i];
        const sameRange = cur.offset === prev.offset && cur.size === prev.size;
        if (!sameRange && cur.offset < prev.offset + prev.size) throw new Error('Overlapping entries: ' + cur.key);
    }
    return { header, files: byOffset, unpacked, dataStart };
}

function integrityOf(buf, blockSize) {
    const blocks = [];
    for (let i = 0; i < buf.length; i += blockSize) blocks.push(sha256(buf.subarray(i, i + blockSize)));
    if (buf.length === 0) blocks.push(sha256(buf));
    return { algorithm: 'SHA256', hash: sha256(buf), blockSize, blocks };
}

function verifyArchive(fd, archive) {
    for (const f of archive.files) {
        const ig = f.entry.integrity;
        if (!ig) continue;
        const whole = crypto.createHash('sha256');
        const blocks = [];
        for (let i = 0; i < f.size; i += ig.blockSize) {
            const buf = readAt(fd, Math.min(ig.blockSize, f.size - i), archive.dataStart + f.offset + i);
            whole.update(buf);
            blocks.push(sha256(buf));
        }
        if (f.size === 0) blocks.push(sha256(Buffer.alloc(0)));
        // @electron/asar 3.x also records a trailing empty-block hash when the size is
        // an exact multiple of blockSize; Electron accepts both forms, so do we.
        const EMPTY = sha256(Buffer.alloc(0));
        if (f.size > 0 && f.size % ig.blockSize === 0 && ig.blocks.length === blocks.length + 1 &&
            ig.blocks[blocks.length] === EMPTY) blocks.push(EMPTY);
        if (whole.digest('hex') !== ig.hash || blocks.length !== ig.blocks.length ||
            blocks.some((b, i) => b !== ig.blocks[i])) {
            throw new Error('Integrity mismatch: ' + f.key);
        }
    }
}

function encodeHeader(header) {
    const json = Buffer.from(JSON.stringify(header), 'utf8');
    if (json.length > MAX_HEADER) throw new Error('ASAR header too large');
    const buf = Buffer.alloc(16 + align4(json.length)); // zero padding
    buf.writeUInt32LE(4, 0);
    buf.writeUInt32LE(buf.length - 8, 4);
    buf.writeUInt32LE(buf.length - 12, 8);
    buf.writeUInt32LE(json.length, 12);
    json.copy(buf, 16);
    return buf;
}

// Inserts the payload after a leading "use strict"; (or prepends it). Returns null
// when the file already carries the marker.
function inject(code, payload, marker) {
    if (code.includes(marker)) return null;
    const m = STRICT_RE.exec(code);
    return m ? m[0] + '\n' + payload + '\n' + code.slice(m[0].length) : payload + '\n' + code;
}

// Decodes strict UTF-8 (a leading BOM is dropped, as the old extract/rewrite flow
// did). Returns null for bytes that would not survive a round trip, so such a file
// is left untouched rather than silently mangled.
function decodeUtf8(buf) {
    const body = buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF ? buf.subarray(3) : buf;
    const text = body.toString('utf8');
    return Buffer.from(text, 'utf8').equals(body) ? text : null;
}

function syntaxError(code, isModule) {
    const r = spawnSync(process.execPath, ['--check', '--input-type=' + (isModule ? 'module' : 'commonjs')],
        { input: code, encoding: 'utf8', windowsHide: true, timeout: 120000 });
    if (r.error) return r.error.message;
    return r.status === 0 ? null : (r.stderr || '').trim().split('\n').slice(0, 6).join(' | ') || 'exit ' + r.status;
}

function patchArchive(source, dest, rendererPayload, mainPayload) {
    const started = Date.now();
    const report = {
        ok: true, mainEntry: DEFAULT_MAIN, main: 'missing',
        injected: [], alreadyPatched: [], skipped: [], notUtf8: [], unpacked: [],
        files: 0, bytes: 0, seconds: 0
    };
    const src = fs.openSync(source, 'r');
    let out = null;
    let created = false;
    try {
        const archive = readArchive(src);
        verifyArchive(src, archive);
        report.files = archive.files.length + archive.unpacked.length;
        const read = f => readAt(src, f.size, archive.dataStart + f.offset);

        let isModule = false;
        const pkg = archive.files.find(f => f.key === 'package.json');
        if (pkg) {
            try {
                const meta = JSON.parse(read(pkg).toString('utf8'));
                if (typeof meta.main === 'string' && meta.main) {
                    report.mainEntry = meta.main.replace(/\\/g, '/').replace(/^(\.\/)+/, '');
                }
                isModule = meta.type === 'module';
            } catch (e) { /* keep the default entry */ }
        }

        report.unpacked = archive.unpacked.filter(k => k.startsWith(BUILD_DIR) && k.endsWith('.js'));
        const edits = new Map();
        for (const f of archive.files) {
            if (!f.key.startsWith(BUILD_DIR) || !f.key.endsWith('.js')) continue;
            if (SKIP.has(leaf(f.key))) { report.skipped.push(f.key); continue; }
            const isMain = f.key === report.mainEntry;
            const text = decodeUtf8(read(f));
            if (text === null) { report.notUtf8.push(f.key); continue; }
            const patched = isMain ? inject(text, mainPayload, MAIN_MARKER) : inject(text, rendererPayload, RENDERER_MARKER);
            if (patched === null) {
                if (isMain) report.main = 'already'; else report.alreadyPatched.push(f.key);
                continue;
            }
            if (isMain) {
                // A syntax error in the entry keeps Claude from starting at all, and no
                // try/catch can guard a parse error -- refuse before writing anything.
                const err = syntaxError(patched, isModule);
                if (err) throw new Error('Patched main entry ' + f.key + ' fails node --check: ' + err);
                report.main = 'injected';
            } else {
                report.injected.push(f.key);
            }
            edits.set(f.key, Buffer.from(patched, 'utf8'));
        }

        // New layout: original offset order, edited files resized, repeated ranges of
        // unedited content still shared.
        const writes = [];
        const shared = new Map();
        let offset = 0;
        for (const f of archive.files) {
            const edited = edits.get(f.key);
            const range = f.offset + ':' + f.size;
            if (!edited && shared.has(range)) { f.entry.offset = shared.get(range); continue; }
            f.entry.offset = String(offset);
            if (edited) {
                f.entry.size = edited.length;
                if (f.entry.integrity) f.entry.integrity = integrityOf(edited, f.entry.integrity.blockSize);
            } else {
                shared.set(range, f.entry.offset);
            }
            writes.push({ f, edited });
            offset += edited ? edited.length : f.size;
        }

        out = fs.openSync(dest, 'wx'); // never overwrite or follow an existing path
        created = true;
        writeAll(out, encodeHeader(archive.header));
        for (const { f, edited } of writes) {
            if (edited) { writeAll(out, edited); continue; }
            for (let i = 0; i < f.size; i += CHUNK) {
                writeAll(out, readAt(src, Math.min(CHUNK, f.size - i), archive.dataStart + f.offset + i));
            }
        }
        fs.fsyncSync(out);
        fs.closeSync(out);
        out = null;

        const check = fs.openSync(dest, 'r');
        try {
            const result = readArchive(check);
            verifyArchive(check, result);
            if (result.files.length + result.unpacked.length !== report.files) throw new Error('Entry count changed');
            report.bytes = fs.fstatSync(check).size;
        } finally { fs.closeSync(check); }

        report.seconds = (Date.now() - started) / 1000;
        return report;
    } catch (e) {
        if (out !== null) { try { fs.closeSync(out); } catch (_) { /* already closed */ } }
        if (created) { try { fs.unlinkSync(dest); } catch (_) { /* best effort */ } }
        throw e;
    } finally {
        fs.closeSync(src);
    }
}

// patch.ps1 decodes stdout with the console code page, so keep the JSON pure ASCII.
function asciiJson(value) {
    return JSON.stringify(value).replace(/[\u007f-\uffff]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
}

module.exports = { patchArchive, readArchive, verifyArchive, encodeHeader, integrityOf, inject, decodeUtf8 };

if (require.main === module) {
    // Usage: node asar-patch.cjs <source.asar> <dest.asar> <renderer-payload.js> <main-payload.js>
    // Prints exactly one JSON line: the report, or { ok: false, error }.
    let result;
    try {
        const [source, dest, rendererFile, mainFile] = process.argv.slice(2);
        if (!mainFile) throw new Error('usage: asar-patch.cjs <source> <dest> <renderer.js> <main.js>');
        result = patchArchive(source, dest, fs.readFileSync(rendererFile, 'utf8'), fs.readFileSync(mainFile, 'utf8'));
    } catch (e) {
        result = { ok: false, error: String(e && e.message || e) };
        process.exitCode = 1;
    }
    process.stdout.write(asciiJson(result) + '\n');
}
