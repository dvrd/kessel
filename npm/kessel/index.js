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

const ASYNC_STACK_MIN_BYTES = 2 * 1024 * 1024;
const nativeAsyncStackReady = prepareNativeAsyncStack();
const lib = koffi.load(findLib());

function prepareNativeAsyncStack() {
  if (koffi.config().async_stack_size >= ASYNC_STACK_MIN_BYTES) return true;
  try {
    // Match Koffi's default synchronous stack. The parser can need much
    // more than the 128 KiB reserved for a default asynchronous call.
    koffi.config({ async_stack_size: ASYNC_STACK_MIN_BYTES });
    return true;
  } catch (error) {
    // Other consumers can lock the shared config by loading a library first.
    if (error.message !== 'Cannot change Koffi configuration once a library has been loaded') throw error;
    return false;
  }
}

// Handle-based ParseResult. The `handle` field is an opaque owning pointer
// returned by kessel_parse_binary; the caller MUST pass it back to
// kessel_free_result once the buffer has been copied into JS-owned memory.
// Moving the free off a thread-local slot lets parseAsync hand the parse
// to a libuv worker thread and free from the main thread without leaking.
// Koffi registers named types across modules. Anonymous structs allow
// separate installations to bind their own ABI in the same process.
const ParseResult = koffi.struct({
  handle:  'void *',
  buf_ptr: 'void *',
  buf_len: 'int32',
});

const _parse_binary = lib.func('kessel_parse_binary', ParseResult, ['void *', 'int32', 'int32']);
const _free_result  = lib.func('kessel_free_result',  'void',       ['void *']);
let _lint_binary = null;
try {
  _lint_binary = lib.func('kessel_lint_binary', ParseResult, [
    'void *', 'int32', 'void *', 'int32', 'int32', 'void *', 'int32',
  ]);
} catch (_) {
  // Older development libraries don't export kessel_lint_binary; lintSync
  // then throws a clear message until the shared library is rebuilt.
}
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
  return finishParse(result, source, sourceBuf, filename);
}

/**
 * Asynchronously parse source off the calling thread and return an
 * ESTree-compatible AST. Uses libuv or a dedicated Node worker depending
 * on Koffi's stack configuration.
 *
 * @param {string} filename  File path or synthetic name (drives language detection).
 * @param {string} source    Source code to parse.
 * @param {object} [opts]    Same shape as parseSync's opts.
 * @returns {Promise<{ program: object, errors: Array }>}
 */
function parseAsync(filename, source, opts) {
  const sourceBuf = Buffer.from(source, 'utf8');
  if (!nativeAsyncStackReady) {
    const { parseOnWorker } = require('./async-fallback');
    return parseOnWorker(filename, source, opts, koffi.config().max_async_calls);
  }
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
      try { resolve(finishParse(result, source, sourceBuf, filename)); }
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
function finishParse(result, source, sourceBytes, filename) {
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

  let buf;
  try {
    buf = copyNativeBytes(result.buf_ptr, result.buf_len);
  } finally {
    _free_result(result.handle);
  }

  const decoded = decode(buf, source, sourceBytes);
  enrichErrors(decoded.errors, source, filename);
  return decoded;
}

function copyNativeBytes(pointer, length) {
  // Copy before freeing the native result. Koffi's typed-array decoder can
  // crash when a different Koffi version has already been loaded.
  return Buffer.from(new Uint8Array(koffi.view(pointer, length)));
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

// ---------------------------------------------------------------------------
// Codegen FFI
// ---------------------------------------------------------------------------
//
// Mirror of `kessel codegen` on the CLI. Returns { code, map?, errors }.
// `code` is the generated source string. `map` is only present when
// `options.sourceMap === true`; it's the parsed v3 source-map object
// (not a string — the JSON has already been round-tripped through
// JSON.parse for the caller's convenience). `errors` is non-empty when
// the parse failed, in which case `code` is the empty string.
const CodegenResult = koffi.struct({
  handle:   'void *',
  code_ptr: 'void *',
  code_len: 'int32',
  map_ptr:  'void *',
  map_len:  'int32',
  ok:       'int32',
});

let _codegen = null;
let _free_codegen_result = null;
try {
  _codegen = lib.func('kessel_codegen', CodegenResult, [
    'void *', 'int32',   // src_ptr, src_len
    'void *', 'int32',   // filename_ptr, filename_len
    'int32',             // lang (0=js 1=jsx 2=ts 3=tsx, -1=auto)
    'int32',             // source_type (0=script 1=module)
    'int32',             // minified
    'int32',             // want_sourcemap
  ]);
  _free_codegen_result = lib.func('kessel_free_codegen_result', 'void', ['void *']);
} catch (e) {
  // Older shared libraries don't ship the codegen exports yet; calling
  // `codegen()` then throws with a clearer message than the koffi default.
}

function langCodeFromName(name) {
  if (!name) return -1;
  const lower = name.toLowerCase();
  if (lower.endsWith('.tsx')) return 3;
  if (lower.endsWith('.ts')  || lower.endsWith('.mts') || lower.endsWith('.cts')) return 2;
  if (lower.endsWith('.jsx')) return 1;
  return 0;
}

function codegen(source, options) {
  if (_codegen == null) {
    throw new Error('kessel: native library does not export kessel_codegen — rebuild libkessel');
  }
  if (typeof source !== 'string') {
    throw new TypeError('kessel.codegen(source, options): source must be a string');
  }
  const opts        = options || {};
  const filename    = typeof opts.filename === 'string' ? opts.filename : 'input';
  const minified    = !!opts.minified;
  const wantMap     = !!opts.sourceMap;
  const langOpt     = typeof opts.lang === 'string' ? opts.lang.toLowerCase() : null;
  const langCode    =
    langOpt === 'tsx' ? 3 :
    langOpt === 'ts'  ? 2 :
    langOpt === 'jsx' ? 1 :
    langOpt === 'js'  ? 0 :
    langCodeFromName(filename);
  const sourceType  = opts.sourceType === 'script' ? 0 : 1;

  const srcBytes      = Buffer.from(source, 'utf8');
  const filenameBytes = Buffer.from(filename, 'utf8');

  const r = _codegen(
    srcBytes, srcBytes.length,
    filenameBytes, filenameBytes.length,
    langCode,
    sourceType,
    minified ? 1 : 0,
    wantMap  ? 1 : 0,
  );
  try {
    if (!r.ok) {
      // Native side already declined; signal a failed parse to the
      // caller. We don't have detailed diagnostics here — use
      // parseSync to surface those if needed.
      return { code: '', map: null, errors: [{ message: 'parse failed' }] };
    }
    const code = r.code_len > 0
      ? copyNativeBytes(r.code_ptr, r.code_len).toString('utf8')
      : '';
    let map = null;
    if (wantMap && r.map_len > 0) {
      const mapBytes = copyNativeBytes(r.map_ptr, r.map_len).toString('utf8');
      map = JSON.parse(mapBytes);
    }
    return { code, map, errors: [] };
  } finally {
    if (r.handle) _free_codegen_result(r.handle);
  }
}

// ---------------------------------------------------------------------------
// Lint FFI — run the linter (pass 4) and return diagnostics.
// ---------------------------------------------------------------------------
//
// Serializes a `{ 'rule-name': 'off'|'warn'|'error' }` map into the compact
// newline-separated `name:level` wire format kessel_lint_binary expects, or
// returns null when there are no overrides (the native side then runs the
// default rule set). Non-string levels are skipped; the native side ignores
// unknown rule names.
function serializeRules(rules) {
  if (!rules || typeof rules !== 'object') return null;
  const lines = [];
  for (const name of Object.keys(rules)) {
    const level = rules[name];
    if (typeof level !== 'string') continue;
    lines.push(`${name}:${level}`);
  }
  if (lines.length === 0) return null;
  return Buffer.from(lines.join('\n'), 'utf8');
}

// Decodes the compact lint wire format emitted by kessel_lint_binary
// (see src/lib_exports.odin). Each diagnostic carries a byte span, a severity,
// a message, and either a K-code (parser/checker) or an L-code (lint rule).

function decodeLintBuffer(buf) {
  const diagnostics = [];
  if (buf.length < 4) return diagnostics;
  let off = 0;
  const count = buf.readUInt32LE(off); off += 4;
  for (let i = 0; i < count; i++) {
    const start = buf.readUInt32LE(off); off += 4;
    const end = buf.readUInt32LE(off); off += 4;
    const codeNum = buf.readUInt16LE(off); off += 2;
    const severity = buf.readUInt8(off); off += 1;
    const isLint = buf.readUInt8(off); off += 1;
    const msgLen = buf.readUInt32LE(off); off += 4;
    const message = buf.toString('utf8', off, off + msgLen); off += msgLen;
    let code = '';
    if (codeNum !== 0) {
      code = (isLint ? 'L' : 'K') + String(codeNum).padStart(4, '0');
    }
    diagnostics.push({
      start, end, message, code,
      severity: severity === 1 ? 'warning' : 'error',
    });
  }
  return diagnostics;
}

/**
 * Lint source code synchronously and return diagnostics.
 *
 * Runs kessel's built-in rule set (no-debugger, no-empty, no-dupe-keys,
 * no-sparse-arrays, no-dupe-class-members by default) plus any parse errors.
 * The returned diagnostics carry `start`/`end` byte offsets, 1-based
 * `line`/`column`, a `severity` ('error' | 'warning'), a stable `code`
 * (`L####` for lint rules, `K####` for parser/checker), and a `message`.
 *
 * @param {string} filename  File path or synthetic name (drives lang detection).
 * @param {string} source    Source code to lint.
 * @param {object} [opts]    Options: { lang: 'js'|'jsx'|'ts'|'tsx',
 *                           rules: { 'no-undef': 'error', 'eqeqeq': 'off' } }.
 *                           `rules` maps a kebab-case rule name to a level
 *                           ('off' | 'warn' | 'error'); unknown names are
 *                           ignored. Overrides the built-in default rule set.
 * @returns {{ diagnostics: Array }}
 */
function lintSync(filename, source, opts) {
  if (!_lint_binary) {
    throw new Error('kessel: native library does not export kessel_lint_binary — rebuild libkessel');
  }
  if (typeof source !== 'string') {
    throw new TypeError('kessel.lintSync(filename, source, opts): source must be a string');
  }
  const sourceBuf = Buffer.from(source, 'utf8');
  const filenameBuf = Buffer.from(filename || 'lib', 'utf8');
  const lang = resolveLang(filename, opts);
  const rulesBuf = serializeRules(opts && opts.rules);
  const result = _lint_binary(
    sourceBuf, sourceBuf.length, filenameBuf, filenameBuf.length, lang,
    rulesBuf, rulesBuf ? rulesBuf.length : 0,
  );
  if (!result.buf_ptr || result.buf_len <= 0) {
    if (result.handle) _free_result(result.handle);
    return { diagnostics: [] };
  }
  let buf;
  try {
    buf = copyNativeBytes(result.buf_ptr, result.buf_len);
  } finally {
    _free_result(result.handle);
  }
  const diagnostics = decodeLintBuffer(buf);
  enrichErrors(diagnostics, source, filename);
  return { diagnostics };
}

module.exports = { parseSync, parseAsync, codegen, lintSync };
