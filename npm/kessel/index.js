/**
 * kessel — fast JavaScript/TypeScript/JSX/TSX parser.
 *
 * Native shared library binding. No process spawn, no IPC.
 * Returns ESTree-compatible ASTs.
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

  // 1. Project-local build (monorepo / development)
  const local = path.resolve(__dirname, '../../bin/libkessel.' + ext);
  if (fs.existsSync(local)) return local;

  // 2. Bundled platform binary
  const bundled = path.join(__dirname, 'bin', `libkessel-${process.platform}-${process.arch}.${ext}`);
  if (fs.existsSync(bundled)) return bundled;

  throw new Error(
    `kessel: cannot find libkessel.${ext}\n` +
    `  tried: ${local}\n` +
    `  tried: ${bundled}\n` +
    `  build: task build:lib`
  );
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
  const lang = opts.lang ? (LANG[opts.lang] ?? LANG.js) : detectLang(filename);
  const sourceBuf = Buffer.from(source, 'utf8');

  const result = _parse_binary(sourceBuf, sourceBuf.length, lang);

  if (!result.buf_ptr || result.buf_len <= 0) {
    _free_result();
    return {
      program: { type: 'Program', body: [], sourceType: 'script', start: 0, end: 0 },
      errors: [{ message: 'Parse failed' }],
    };
  }

  const buf = Buffer.from(koffi.decode(result.buf_ptr, koffi.array('uint8', result.buf_len)));
  _free_result();

  return decode(buf, source);
}

module.exports = { parseSync };
