/**
 * kessel — fast JavaScript/TypeScript/JSX/TSX parser.
 *
 * Native shared library binding via koffi FFI + binary AST decode.
 * No process spawn, no JSON serialization. Returns ESTree-compatible ASTs.
 *
 * Usage:
 *   const { parseSync, parseAsync } = require('@dvrdlibs/kessel');
 *   const { program, errors } = parseSync('app.js', source);
 *   const { program, errors } = await parseAsync('app.js', source);
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

// Handle-based ParseResult. The `handle` field is an opaque owning pointer
// returned by kessel_parse_binary; the caller MUST pass it back to
// kessel_free_result once the buffer has been copied into JS-owned memory.
// Moving the free off a thread-local slot lets parseAsync hand the parse
// to a libuv worker thread and free from the main thread without leaking.
const ParseResult = koffi.struct('KesselParseResult', {
  handle:  'void *',
  buf_ptr: 'void *',
  buf_len: 'int32',
});

const _parse_binary = lib.func('kessel_parse_binary', ParseResult, ['void *', 'int32', 'int32']);
const _free_result  = lib.func('kessel_free_result',  'void',       ['void *']);
let _parse_binary_v2 = null;
try {
  _parse_binary_v2 = lib.func('kessel_parse_binary_v2', ParseResult, [
    'void *', 'int32', 'void *', 'int32',
    'int32', 'int32', 'int32', 'int32', 'int32', 'int32', 'int32',
    'int32', 'int32', 'int32', 'int32',
  ]);
} catch (_) {
  // Older development libraries expose only kessel_parse_binary. Keep a
  // compatibility path so source checkouts fail soft until rebuilt.
}

// ---------------------------------------------------------------------------
// Language detection
// ---------------------------------------------------------------------------

const LANG = { js: 0, jsx: 1, ts: 2, tsx: 3 };
const SOURCE_TYPE = { unambiguous: -1, script: 0, module: 1 };
const MODE = { ast: 0, parse: 1, full: 2 };

function detectLang(filename) {
  const ext = path.extname(filename).toLowerCase();
  switch (ext) {
    case '.ts':  case '.mts': case '.cts': return LANG.ts;
    case '.tsx': return LANG.tsx;
    case '.jsx': return LANG.jsx;
    default:     return LANG.js;
  }
}

function resolveLang(filename, opts) {
  return opts && opts.lang ? (LANG[opts.lang] ?? LANG.js) : detectLang(filename);
}

function resolveLangOverride(opts) {
  if (!opts || opts.lang == null) return -1;
  if (Object.prototype.hasOwnProperty.call(LANG, opts.lang)) return LANG[opts.lang];
  throw new TypeError(`kessel: invalid lang option: ${opts.lang}`);
}

function resolveSourceType(opts) {
  if (!opts || opts.sourceType == null) return -1;
  if (Object.prototype.hasOwnProperty.call(SOURCE_TYPE, opts.sourceType)) {
    return SOURCE_TYPE[opts.sourceType];
  }
  throw new TypeError(`kessel: invalid sourceType option: ${opts.sourceType}`);
}

function resolveMode(opts) {
  if (!opts || opts.mode == null) return MODE.ast;
  if (Object.prototype.hasOwnProperty.call(MODE, opts.mode)) return MODE[opts.mode];
  throw new TypeError(`kessel: invalid mode option: ${opts.mode}`);
}

function boolOption(opts, name) {
  return opts && opts[name] === true ? 1 : 0;
}

function maybeBoolOption(opts, name) {
  if (!opts || opts[name] == null) return -1;
  return opts[name] ? 1 : 0;
}

function resolveNativeOptions(opts) {
  const mode = resolveMode(opts);
  const showSemanticErrors = mode === MODE.full || boolOption(opts, 'showSemanticErrors') === 1;
  return {
    version: 1,
    lang: resolveLangOverride(opts),
    sourceType: resolveSourceType(opts),
    strictSourceType: boolOption(opts, 'strictSourceType'),
    forceStrict: boolOption(opts, 'forceStrict'),
    preserveParens: boolOption(opts, 'preserveParens'),
    astOnly: showSemanticErrors || mode !== MODE.ast ? 0 : 1,
    showSemanticErrors: showSemanticErrors ? 1 : 0,
    sourceIsDts: maybeBoolOption(opts, 'sourceIsDts'),
    commonjs: maybeBoolOption(opts, 'commonjs'),
    disallowAmbiguousJSXLike: boolOption(opts, 'disallowAmbiguousJSXLike'),
  };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Parse source code synchronously and return an ESTree-compatible AST.
 *
 * Blocks the calling thread for the entire parse. Use {@link parseAsync}
 * to keep the Node event loop responsive while a large source is parsing,
 * or to parse many files concurrently across libuv's worker pool.
 *
 * @param {string} filename  File path or synthetic name (drives language detection).
 * @param {string} source    Source code to parse.
 * @param {object} [opts]    Options:
 *   - lang: 'js' | 'jsx' | 'ts' | 'tsx'  (overrides filename detection)
 *   - sourceType: 'script' | 'module' | 'unambiguous'
 *   - mode: 'ast' | 'parse' | 'full'
 * @returns {{ program: object, errors: Array }}
 */
function parseSync(filename, source, opts) {
  const sourceBuf = Buffer.from(source, 'utf8');
  const result = callParseBinary(sourceBuf, filename, opts);
  return finishParse(result, source, filename);
}

/**
 * Parse source code asynchronously on a libuv worker thread.
 *
 * Same signature and return shape as {@link parseSync}, but the native
 * parse runs off the Node main thread via koffi's `.async()`. The Node
 * event loop stays responsive during the parse and concurrent calls fan
 * out across libuv's worker pool (default 4 threads, raise with
 * `UV_THREADPOOL_SIZE` env var if you need more parallelism).
 *
 * Throughput characteristics:
 *   - For one-shot parses, parseAsync is marginally slower than parseSync
 *     because the FFI call has a small thread-handoff overhead (~10-50µs).
 *   - For N concurrent parses on M-core hosts, parseAsync scales close to
 *     min(N, UV_THREADPOOL_SIZE) until the pool saturates.
 *   - The post-parse JS work (binary decode + enrichErrors) still runs on
 *     the awaiting thread; only the native parse itself is offloaded.
 *
 * @param {string} filename  File path or synthetic name (drives language detection).
 * @param {string} source    Source code to parse.
 * @param {object} [opts]    Same shape as parseSync's opts.
 * @returns {Promise<{ program: object, errors: Array }>}
 */
function parseAsync(filename, source, opts) {
  const sourceBuf = Buffer.from(source, 'utf8');
  // koffi.func.async runs the FFI call on a libuv worker thread and
  // delivers the result via a Node-style callback. We wrap it as a
  // Promise so the public API matches OXC's parseAsync shape. The
  // buffer the FFI hands back is owned by the heap-allocated handle
  // inside the struct, so freeing it via that handle works from any
  // thread — we can safely free back on the main thread after the
  // await without touching whatever worker thread did the parse.
  return new Promise(function (resolve, reject) {
    callParseBinaryAsync(sourceBuf, filename, opts, function (err, result) {
      if (err) { reject(err); return; }
      try { resolve(finishParse(result, source, filename)); }
      catch (e) { reject(e); }
    });
  });
}

function callParseBinary(sourceBuf, filename, opts) {
  if (!_parse_binary_v2) {
    const lang = resolveLang(filename, opts);
    return _parse_binary(sourceBuf, sourceBuf.length, lang);
  }

  const filenameBuf = Buffer.from(filename || 'lib', 'utf8');
  const native = resolveNativeOptions(opts);
  return _parse_binary_v2(
    sourceBuf, sourceBuf.length,
    filenameBuf, filenameBuf.length,
    native.version,
    native.lang,
    native.sourceType,
    native.strictSourceType,
    native.forceStrict,
    native.preserveParens,
    native.astOnly,
    native.showSemanticErrors,
    native.sourceIsDts,
    native.commonjs,
    native.disallowAmbiguousJSXLike
  );
}

function callParseBinaryAsync(sourceBuf, filename, opts, callback) {
  if (!_parse_binary_v2) {
    const lang = resolveLang(filename, opts);
    _parse_binary.async(sourceBuf, sourceBuf.length, lang, callback);
    return;
  }

  const filenameBuf = Buffer.from(filename || 'lib', 'utf8');
  const native = resolveNativeOptions(opts);
  _parse_binary_v2.async(
    sourceBuf, sourceBuf.length,
    filenameBuf, filenameBuf.length,
    native.version,
    native.lang,
    native.sourceType,
    native.strictSourceType,
    native.forceStrict,
    native.preserveParens,
    native.astOnly,
    native.showSemanticErrors,
    native.sourceIsDts,
    native.commonjs,
    native.disallowAmbiguousJSXLike,
    callback
  );
}

// Shared post-FFI pipeline: validate, copy out, free the handle, decode,
// enrich. Centralised so parseSync and parseAsync surface identical
// errors and identical AST shapes — the only difference between the two
// is which thread runs `_parse_binary`.
function finishParse(result, source, filename) {
  if (!result.buf_ptr || result.buf_len <= 0) {
    // Handle may still be non-null even when the parse couldn't produce a
    // buffer (e.g. parse_job_open_inline failed); free defensively before
    // returning the synthetic empty Program so we never leak the LibResult.
    if (result.handle) _free_result(result.handle);
    return {
      program: { type: 'Program', body: [], sourceType: 'script', start: 0, end: 0 },
      errors: [{ message: 'Parse failed', filename, start: 0, end: 0, line: 1, column: 1 }],
    };
  }

  const buf = Buffer.from(koffi.decode(result.buf_ptr, koffi.array('uint8', result.buf_len)));
  _free_result(result.handle);

  const decoded = decode(buf, source);
  enrichErrors(decoded.errors, source, filename);
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
  // Encode once: the Odin parser tracks offsets in UTF-8 bytes, so the
  // line-start table must be built over the SAME byte stream or any LF
  // that follows a non-ASCII character will land at the wrong index.
  // Buffer.from is the canonical Node UTF-8 encoder; it shares no
  // allocation with the koffi FFI buffer.
  const sourceBytes = Buffer.from(source, 'utf8');
  const lineStarts = computeLineStarts(sourceBytes);
  for (const err of errors) {
    err.filename = filename;
    const [line, column] = offsetToLineColumn(err.start, lineStarts);
    err.line = line;
    err.column = column;
  }
}

function computeLineStarts(sourceBytes) {
  // Offsets where each line begins, measured in UTF-8 bytes — same unit
  // as ParseError.start/end and as everything the Odin parser sees.
  // Previously we walked source.charCodeAt(i), which is a UTF-16 code-
  // unit index; for ASCII / BMP source the two indexings agreed, but a
  // non-BMP character (e.g. an emoji, encoded as 4 UTF-8 bytes / 2 UTF-16
  // surrogates) pushed every subsequent LF's table entry low by one
  // position per non-BMP char between offset 0 and the LF — shifting
  // line numbers off for everything past the first non-BMP byte.
  //
  // We only scan for LF (0x0A): CRLF sequences contribute one LF which
  // we capture; bare CR (classic Mac) is rare on disk and unsupported
  // here without losing fidelity for the common case.
  const starts = [0];
  for (let i = 0; i < sourceBytes.length; i++) {
    if (sourceBytes[i] === 0x0A) starts.push(i + 1);
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

module.exports = { parseSync, parseAsync };
