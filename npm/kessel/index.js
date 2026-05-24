/**
 * kessel — fast JavaScript/TypeScript/JSX/TSX parser.
 *
 * Native shared library binding via koffi FFI + binary AST decode.
 * No process spawn, no JSON serialization. Returns ESTree-compatible ASTs.
 *
 * Usage:
 *   const { parseSync } = require('kessel');
 *   const { program, errors } = parseSync('app.js', source);
 */

'use strict';

const koffi = require('koffi');
const path = require('path');
const fs = require('fs');
const { decode } = require('./binary-reader');

// ---------------------------------------------------------------------------
// Locate the shared library
// ---------------------------------------------------------------------------

function findLib() {
  const ext = process.platform === 'darwin' ? 'dylib'
            : process.platform === 'win32' ? 'dll' : 'so';

  // 1. Project-local build (monorepo / development). From npm/kessel/index.js
  //    two levels up is the repo root, where `task build:lib` writes.
  const local = path.resolve(__dirname, '../../bin/libkessel.' + ext);
  if (fs.existsSync(local)) return local;

  // 2. Production: resolve the platform-specific sub-package. npm only
  //    installs the optional dependency whose `os` / `cpu` fields match,
  //    so this require() resolves to exactly one sub-package on disk.
  const subpkg = `@dvrdlibs/kessel-${process.platform}-${process.arch}`;
  try {
    return require(subpkg);
  } catch (err) {
    throw new Error(
      `kessel: no prebuilt binary for ${process.platform}-${process.arch}\n` +
      `  supported: darwin-arm64, darwin-x64, linux-x64, linux-arm64, win32-x64\n` +
      `  expected sub-package: ${subpkg}\n` +
      `  underlying error: ${err && err.message}\n` +
      `  for unsupported platforms, build from source: https://github.com/dvrd/kessel`
    );
  }
}

// ---------------------------------------------------------------------------
// Load the library and define FFI signatures
// ---------------------------------------------------------------------------

const lib = koffi.load(findLib());

const ParseResult = koffi.struct('KesselParseResult', {
  buf_ptr: 'void *',
  buf_len: 'int32',
});

const _parse_binary = lib.func('kessel_parse_binary', ParseResult, ['void *', 'int32', 'int32']);
const _free_result = lib.func('kessel_free_result', 'void', []);

// ---------------------------------------------------------------------------
// Language detection
// ---------------------------------------------------------------------------

const LANG = { js: 0, jsx: 1, ts: 2, tsx: 3 };

function detectLang(filename) {
  const ext = path.extname(filename).toLowerCase();
  switch (ext) {
    case '.ts':  case '.mts': case '.cts': return LANG.ts;
    case '.tsx': return LANG.tsx;
    case '.jsx': return LANG.jsx;
    default:     return LANG.js;
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Parse source code synchronously and return an ESTree-compatible AST.
 *
 * @param {string} filename  File path or synthetic name (for language detection)
 * @param {string} source    Source code to parse
 * @param {object} [opts]    Options:
 *   - lang: 'js' | 'jsx' | 'ts' | 'tsx'  (overrides filename detection)
 * @returns {{ program: object, errors: Array }}
 */
function parseSync(filename, source, opts = {}) {
  const _dbg = (m) => process.stderr.write('[PS] ' + filename + ' ' + m + '\n');
  _dbg('enter src.len=' + source.length);
  const lang = opts.lang ? (LANG[opts.lang] ?? LANG.js) : detectLang(filename);
  const sourceBuf = Buffer.from(source, 'utf8');
  _dbg('pre-ffi sourceBuf.len=' + sourceBuf.length + ' lang=' + lang);

  const result = _parse_binary(sourceBuf, sourceBuf.length, lang);
  _dbg('post-ffi buf_ptr=' + !!result.buf_ptr + ' buf_len=' + result.buf_len);

  if (!result.buf_ptr || result.buf_len <= 0) {
    _free_result();
    return {
      program: { type: 'Program', body: [], sourceType: 'script', start: 0, end: 0 },
      errors: [{ message: 'Parse failed', filename, start: 0, end: 0, line: 1, column: 1 }],
    };
  }

  const buf = Buffer.from(koffi.decode(result.buf_ptr, koffi.array('uint8', result.buf_len)));
  _dbg('post-koffi-decode buf.len=' + buf.length);
  _free_result();
  _dbg('post-free');

  const decoded = decode(buf, source);
  _dbg('post-decode errors=' + decoded.errors.length);
  enrichErrors(decoded.errors, source, filename);
  _dbg('post-enrich');
  return decoded;
}

// ---------------------------------------------------------------------------
// Error enrichment — attach filename + line/column to each diagnostic.
//
// The Odin parser emits byte offsets; we expose them as `start`/`end` and
// also compute 1-based line/column for human-readable output. Line offsets
// are computed once per parse and shared across all errors in that call.
// ---------------------------------------------------------------------------

function enrichErrors(errors, source, filename) {
  if (errors.length === 0) return;
  const lineStarts = computeLineStarts(source);
  for (const err of errors) {
    err.filename = filename;
    const [line, column] = offsetToLineColumn(err.start, lineStarts);
    err.line = line;
    err.column = column;
  }
}

function computeLineStarts(source) {
  // Offsets where each line begins. Counting LF on the JS string is
  // accurate for ASCII / BMP source (the common case); for source with
  // characters outside the BMP, byte-based offsets from the parser may
  // disagree with JS string indices. Documented in ParseError JSDoc.
  const starts = [0];
  for (let i = 0; i < source.length; i++) {
    if (source.charCodeAt(i) === 10) starts.push(i + 1);
  }
  return starts;
}

function offsetToLineColumn(offset, lineStarts) {
  // Binary search for the largest lineStarts[i] <= offset.
  let lo = 0, hi = lineStarts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >>> 1;
    if (lineStarts[mid] <= offset) lo = mid;
    else hi = mid - 1;
  }
  return [lo + 1, offset - lineStarts[lo] + 1];
}

module.exports = { parseSync };
