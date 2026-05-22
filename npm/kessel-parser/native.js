/**
 * kessel-parser/native — direct shared library binding (no process spawn).
 *
 * Loads libkessel.dylib/.so via koffi and calls kessel_parse_binary directly.
 * Combined with binary-reader.js, this gives the fastest possible parseSync:
 * ~2ms for lodash.js (vs OXC NAPI 3.3ms).
 *
 * Usage:
 *   const { parseSync } = require('kessel-parser/native');
 *   const { program, errors } = parseSync('test.js', source);
 */

'use strict';

const koffi = require('koffi');
const path = require('path');
const fs = require('fs');
const { decode } = require('./binary-reader');

// Locate the shared library
function findLib() {
  // Project-local build
  const local = path.resolve(__dirname, '../../bin/libkessel.dylib');
  if (fs.existsSync(local)) return local;

  // Linux
  const localSo = path.resolve(__dirname, '../../bin/libkessel.so');
  if (fs.existsSync(localSo)) return localSo;

  // Bundled
  const platform = process.platform;
  const arch = process.arch;
  const ext = platform === 'darwin' ? 'dylib' : 'so';
  const bundled = path.join(__dirname, 'bin', `libkessel-${platform}-${arch}.${ext}`);
  if (fs.existsSync(bundled)) return bundled;

  throw new Error(
    `kessel-parser/native: cannot locate libkessel.\n` +
    `Tried: ${local}\n` +
    `Build: odin build src -build-mode:shared -out:bin/libkessel.dylib -o:speed -no-bounds-check`
  );
}

// Load the library
const lib = koffi.load(findLib());

// Define the C function signature.
// kessel_parse_binary(source_ptr: *u8, source_len: i32, lang: i32) -> (*u8, i32)
// Odin returns multiple values as a struct in C ABI.
// Actually — Odin's multi-return becomes a struct { buf_ptr: *u8, buf_len: i32 }
// On ARM64/x86-64 this is returned in registers (ptr in x0, len in x1).

// koffi approach: define the return struct
const ParseResult = koffi.struct('ParseResult', {
  buf_ptr: 'void *',
  buf_len: 'int32',
});

const kessel_parse_binary = lib.func('kessel_parse_binary', ParseResult, ['void *', 'int32', 'int32']);
const kessel_free_result = lib.func('kessel_free_result', 'void', []);

// Lang enum
const LANG = { js: 0, jsx: 1, ts: 2, tsx: 3 };

/**
 * parseSync — parse source code and return an ESTree AST.
 *
 * @param {string} filename - Used for language detection (.js/.ts/.jsx/.tsx)
 * @param {string} source - Source code to parse
 * @param {object} [opts] - Options: { sourceType, lang }
 * @returns {{ program: object, errors: Array }}
 */
function parseSync(filename, source, opts = {}) {
  // Determine language from extension
  let lang = LANG.jsx; // default
  if (opts.lang) {
    lang = LANG[opts.lang] ?? LANG.jsx;
  } else {
    const ext = path.extname(filename).toLowerCase();
    if (ext === '.ts' || ext === '.mts' || ext === '.cts') lang = LANG.ts;
    else if (ext === '.tsx') lang = LANG.tsx;
    else if (ext === '.jsx') lang = LANG.jsx;
    else lang = LANG.js;
  }

  // Encode source as UTF-8 buffer
  const sourceBuf = Buffer.from(source, 'utf8');

  // Call the native function
  const result = kessel_parse_binary(sourceBuf, sourceBuf.length, lang);

  if (!result.buf_ptr || result.buf_len <= 0) {
    kessel_free_result();
    return { program: { type: 'Program', body: [], sourceType: 'script', start: 0, end: 0 }, errors: [{ message: 'Parse failed' }] };
  }

  // Copy the buffer (we need to free the native memory)
  const buf = Buffer.from(koffi.decode(result.buf_ptr, koffi.array('uint8', result.buf_len)));

  // Free native result
  kessel_free_result();

  // Decode binary AST
  return decode(buf, source);
}

module.exports = { parseSync };
