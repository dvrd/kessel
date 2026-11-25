/**
 * kessel — fast JavaScript/TypeScript/JSX/TSX parser.
 *
 * Native shared library binding via koffi FFI + binary AST decode.
 * The parser returns ESTree-compatible ASTs without spawning a process or serializing JSON.
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
// Electron's V8 memory cage requires buffers allocated by the runtime. Copy
// into a JS-owned Buffer before the parser releases its result.
const copyIntoElectronBuffer = process.versions.electron
  ? koffi.load(process.platform === 'win32' ? 'ucrtbase.dll' : null)
      .func('memcpy', 'void *', ['void *', 'const void *', 'size_t'])
  : null;

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

function optionalTool(symbol, parameters) {
  try {
    return lib.func(symbol, ParseResult, parameters);
  } catch (_) {
    // A published parser library from before these tools can still serve parsing.
    return null;
  }
}

const _module_lex = optionalTool('kessel_module_lex', ['void *', 'int32']);
const _regex_ast = optionalTool('kessel_regex_ast', ['void *', 'int32', 'void *', 'int32']);
const _resolve_module = optionalTool('kessel_resolve_module', ['void *', 'int32']);
const _lint_fix = optionalTool('kessel_lint_fix', ['void *', 'int32', 'void *', 'int32', 'void *', 'int32']);
const _lint_project = optionalTool('kessel_lint_project', ['void *', 'int32', 'void *', 'int32', 'void *', 'int32']);
const _format = optionalTool('kessel_format', ['void *', 'int32', 'void *', 'int32', 'void *', 'int32']);
const _isolated_declaration = optionalTool('kessel_isolated_declaration', ['void *', 'int32', 'void *', 'int32']);
const _transform = optionalTool('kessel_transform', ['void *', 'int32', 'void *', 'int32', 'void *', 'int32']);
const _minify = optionalTool('kessel_minify', ['void *', 'int32', 'void *', 'int32', 'void *', 'int32']);
const _bundle = optionalTool('kessel_bundle', ['void *', 'int32']);

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
  if (copyIntoElectronBuffer) {
    const buffer = Buffer.allocUnsafe(length);
    copyIntoElectronBuffer(buffer, pointer, length);
    return buffer;
  }
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
  // Diagnostic offsets and columns count UTF-8 bytes. CRLF is one line break.
  const starts = [0];
  for (let i = 0; i < sourceBytes.length; i++) {
    const byte = sourceBytes[i];
    if (byte === 0x0D) {
      if (sourceBytes[i + 1] === 0x0A) i++;
    } else if (byte === 0xE2 && sourceBytes[i + 1] === 0x80 &&
               (sourceBytes[i + 2] === 0xA8 || sourceBytes[i + 2] === 0xA9)) {
      i += 2;
    } else if (byte !== 0x0A) {
      continue;
    }
    starts.push(i + 1);
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
  const settings = Object.create(null);
  let structured = false;
  for (const [name, value] of Object.entries(rules)) {
    if (typeof value === 'string') {
      settings[name] = value === 'allow' ? 'off' : value === 'deny' ? 'error' : value;
      continue;
    }
    if (typeof value !== 'number' && !Array.isArray(value)) continue;
    const [level, ...options] = Array.isArray(value) ? value : [value];
    if (![0, 1, 2, 'allow', 'off', 'warn', 'deny', 'error'].includes(level)) {
      throw new TypeError('Invalid lint severity for ' + name);
    }
    if (options.length > 0 && name === 'prefer-const') {
      const [settings] = options;
      if (options.length !== 1 || !settings || typeof settings !== 'object' || Array.isArray(settings) ||
          Object.entries(settings).some(([key, option]) =>
            key === 'destructuring' ? !['all', 'any'].includes(option) :
            key !== 'ignoreReadBeforeAssign' || typeof option !== 'boolean')) {
        throw new TypeError('Invalid prefer-const options');
      }
    } else if (options.length > 0 && ['exhaustive-deps', 'react/exhaustive-deps', 'react-hooks/exhaustive-deps'].includes(name)) {
      const [config] = options;
      if (options.length !== 1 || !config || typeof config !== 'object' || Array.isArray(config) ||
          Object.keys(config).some(key => key !== 'additionalHooks' || typeof config[key] !== 'string')) {
        throw new TypeError('Invalid exhaustive-deps options');
      }
    } else if (options.length > 0 && name === 'no-fallthrough') {
      const [config] = options;
      if (options.length !== 1 || !config || typeof config !== 'object' || Array.isArray(config) ||
          Object.entries(config).some(([key, value]) => key === 'commentPattern'
            ? value !== null && typeof value !== 'string'
            : !['allowEmptyCase', 'reportUnusedFallthroughComment'].includes(key) || typeof value !== 'boolean')) {
        throw new TypeError('Invalid no-fallthrough options');
      }
    } else if (options.length > 0 && name === 'getter-return') {
      const [settings] = options;
      if (options.length !== 1 || !settings || typeof settings !== 'object' || Array.isArray(settings) ||
          Object.entries(settings).some(([key, value]) => key !== 'allowImplicit' || typeof value !== 'boolean')) {
        throw new TypeError('Invalid getter-return options');
      }
    } else if (options.length > 0 && name === 'no-console') {
      const [config] = options;
      if (options.length !== 1 || !config || typeof config !== 'object' || Array.isArray(config) ||
          Object.keys(config).some(key => key !== 'allow') ||
          ('allow' in config && (!Array.isArray(config.allow) || !config.allow.every(method => typeof method === 'string')))) {
        throw new TypeError('Invalid no-console options');
      }
    } else if (options.length > 0) {
      if (name !== 'eqeqeq' || options.length > 2 || !['always', 'smart', 'allow-null'].includes(options[0])) {
        throw new TypeError('Unsupported lint options for ' + name);
      }
      if (options.length === 2) {
        const extra = options[1];
        if (!extra || typeof extra !== 'object' || Array.isArray(extra) ||
            Object.keys(extra).some(key => key !== 'null' || !['always', 'ignore', 'never'].includes(extra[key]))) {
          throw new TypeError('Invalid eqeqeq null comparison options');
        }
      }
    }
    structured = true;
    settings[name] = value;
  }
  if (structured) return Buffer.from(JSON.stringify(settings), 'utf8');
  const lines = Object.entries(settings).map(([name, level]) => name + ':' + level);
  return lines.length ? Buffer.from(lines.join('\n'), 'utf8') : null;
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
 * @returns {{ diagnostics: Array, output?: string }} Output is present when fixes changed the source.
 */
function lintSync(filename, source, opts) {
  if (!_lint_binary) {
    throw new Error('kessel: native library does not export kessel_lint_binary — rebuild libkessel');
  }
  if (typeof source !== 'string') {
    throw new TypeError('kessel.lintSync(filename, source, opts): source must be a string');
  }
  let sourceBuf = toolInput(source, 'source');
  const filenameBuf = Buffer.from(filename || 'lib', 'utf8');
  const lang = resolveLang(filename, opts);
  let rules = opts && opts.rules;
  if (opts && opts.reportUnusedDisableDirectives !== undefined) {
    const level = opts.reportUnusedDisableDirectives;
    if (!['off', 'warn', 'error'].includes(level)) {
      throw new TypeError('reportUnusedDisableDirectives must be off, warn or error');
    }
    rules = { ...rules, 'unused-disable-directive': level };
  }
  const rulesBuf = serializeRules(rules);
  let output;
  for (const key of ['fix', 'fixSuggestions', 'fixDangerously', 'includeFixes', 'includeSuggestions', 'includeSuppressions']) {
    if (opts?.[key] !== undefined && typeof opts[key] !== 'boolean') {
      throw new TypeError(key + ' must be a boolean');
    }
  }
  const useProject = opts?.workspaceRoot !== undefined;
  const projectDiagnostics = useProject || opts?.includeFixes || opts?.includeSuggestions || opts?.includeSuppressions;
  if (projectDiagnostics || opts?.fix || opts?.fixSuggestions || opts?.fixDangerously) {
    if (useProject && (typeof opts.workspaceRoot !== 'string' || !path.isAbsolute(opts.workspaceRoot))) {
      throw new TypeError('workspaceRoot must be an absolute directory');
    }
    const settings = toolInput(JSON.stringify({
      lang, fix: !!opts.fix, suggestions: !!opts.fixSuggestions, dangerous: !!opts.fixDangerously,
      include_fixes: !!opts.includeFixes, include_suggestions: !!opts.includeSuggestions,
      include_suppressions: !!opts.includeSuppressions,
      rules: rulesBuf?.toString('utf8') || '', workspace: opts.workspaceRoot,
    }), 'options');
    if (projectDiagnostics) {
      const file = useProject ? toolInput(path.resolve(opts.workspaceRoot, filename), 'filename') : filenameBuf;
      const project = readToolResult(_lint_project, 'lintSync project', file, sourceBuf, settings);
      const diagnostics = project.diagnostics || [];
      enrichErrors(diagnostics, project.output ?? source, filename);
      return project.output == null ? { diagnostics } : { diagnostics, output: project.output };
    }
    const fixed = readToolResult(_lint_fix, 'lintSync autofix', filenameBuf, sourceBuf, settings);
    if (typeof fixed.output === 'string') {
      output = fixed.output;
      source = output;
      sourceBuf = toolInput(source, 'output');
    }
  }
  const result = _lint_binary(
    sourceBuf, sourceBuf.length, filenameBuf, filenameBuf.length, lang,
    rulesBuf, rulesBuf ? rulesBuf.length : 0,
  );
  if (!result.buf_ptr || result.buf_len <= 0) {
    if (result.handle) _free_result(result.handle);
    if (result.buf_len === -1) throw new TypeError('Invalid lint rule settings');
    throw new Error('kessel: could not read native lint diagnostics');
  }
  let buf;
  try {
    buf = copyNativeBytes(result.buf_ptr, result.buf_len);
  } finally {
    _free_result(result.handle);
  }
  const diagnostics = decodeLintBuffer(buf);
  enrichErrors(diagnostics, source, filename);
  return output === undefined ? { diagnostics } : { diagnostics, output };
}

function toolInput(value, name) {
  if (typeof value !== 'string') throw new TypeError(`kessel: ${name} must be a string`);
  const buffer = Buffer.from(value, 'utf8');
  if (buffer.length > 0x7fffffff) throw new RangeError(`kessel: ${name} exceeds the native input limit`);
  return buffer;
}

function readToolResult(native, operation, ...inputs) {
  if (!native) throw new Error(`kessel: rebuild the native library to use ${operation}`);
  const result = native(...inputs.flatMap(input => [input, input.length]));
  let payload;
  try {
    if (!result.buf_ptr || result.buf_len <= 0) throw new Error(`kessel: ${operation} failed`);
    payload = copyNativeBytes(result.buf_ptr, result.buf_len).toString('utf8');
  } finally {
    if (result.handle) _free_result(result.handle);
  }
  const value = JSON.parse(payload);
  if (typeof value.code === 'string') {
    const ErrorType = /^Invalid_(Syntax|Pattern|Flags)$/.test(value.code) ? SyntaxError : Error;
    const error = new ErrorType(`kessel: ${value.message || operation + ' failed'}`);
    error.code = value.code;
    if (value.offset !== null) error.offset = value.offset;
    throw error;
  }
  return value;
}

function scanModuleSync(source) {
  return readToolResult(_module_lex, 'scanModuleSync', toolInput(source, 'source'));
}

function parseRegExpSync(pattern, flags = '') {
  return readToolResult(_regex_ast, 'parseRegExpSync',
    toolInput(pattern, 'pattern'), toolInput(flags, 'flags'));
}

function toolStringList(value, name, allowEmpty = false) {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || Array.from(value).some(item =>
    typeof item !== 'string' || (!allowEmpty && item.length === 0) || item.includes('\0'))) {
    const expected = allowEmpty ? 'strings' : 'non-empty strings';
    throw new TypeError(`kessel: ${name} must contain ${expected} without NUL bytes`);
  }
  return value;
}

function resolverManifestFields(value, name) {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) throw new TypeError(`kessel: ${name} must be an array of keys or key paths`);
  return Array.from(value, entry => {
    const path = typeof entry === 'string' ? [entry] : entry;
    if (!Array.isArray(path) || Array.from(path).some(key => typeof key !== 'string')) {
      throw new TypeError(`kessel: ${name} must contain strings or arrays of strings`);
    }
    return path;
  });
}

function resolverOptions(options) {
  if (options === null || typeof options !== 'object' || Array.isArray(options)) {
    throw new TypeError('kessel: resolver options must be an object');
  }
  const { mode = 'import', tsconfig = '', browser = false, preserveSymlinks = false,
    mainFields, exportsFields, importsFields, extensions, mainFiles, modules, conditions, aliases = [], extensionAlias = {},
    roots = [], fallback = [], restrictions = [], fullySpecified, preferRelative = false, preferAbsolute = false,
    resolveToContext = false, explicitConditions = false, tsconfigReferences = false } = options;
  if (mode !== 'import' && mode !== 'require') throw new TypeError('kessel: mode must be import or require');
  if (typeof tsconfig !== 'string') throw new TypeError('kessel: tsconfig must be a string');
  if (typeof browser !== 'boolean' || typeof preserveSymlinks !== 'boolean') {
    throw new TypeError('kessel: browser and preserveSymlinks must be booleans');
  }
  if (!Array.isArray(aliases)) throw new TypeError('kessel: aliases must be an array');
  const switches = { preferRelative, preferAbsolute, resolveToContext, explicitConditions, tsconfigReferences };
  for (const [name, value] of Object.entries(switches)) {
    if (typeof value !== 'boolean') throw new TypeError(`kessel: ${name} must be a boolean`);
  }
  if (fullySpecified !== undefined && typeof fullySpecified !== 'boolean') {
    throw new TypeError('kessel: fullySpecified must be a boolean');
  }
  if (!Array.isArray(fallback)) throw new TypeError('kessel: fallback must be an array');
  if (!Array.isArray(restrictions)) throw new TypeError('kessel: restrictions must be an array');
  if (extensionAlias === null || typeof extensionAlias !== 'object' || Array.isArray(extensionAlias)) {
    throw new TypeError('kessel: extensionAlias must map suffixes to arrays of replacements');
  }
  const suffixes = Object.entries(extensionAlias).map(([from, targets]) => {
    if (from.length === 0 || from.includes('\0') || !Array.isArray(targets)) {
      throw new TypeError('kessel: each extensionAlias entry requires a suffix and an array');
    }
    return [from, toolStringList(targets, 'extensionAlias', true)];
  });
  return {
    mode,
    options: {
      browser, preserve_symlinks: preserveSymlinks, typescript_config: tsconfig,
      exports_fields: resolverManifestFields(exportsFields, 'exportsFields'),
      imports_fields: resolverManifestFields(importsFields, 'importsFields'),
      main_fields: toolStringList(typeof mainFields === 'string' ? [mainFields] : mainFields, 'mainFields', true),
      modules: toolStringList(typeof modules === 'string' ? [modules] : modules, 'modules', true),
      extensions: toolStringList(extensions, 'extensions', true),
      extension_alias: Object.fromEntries(suffixes),
      main_files: toolStringList(mainFiles, 'mainFiles'),
      conditions: toolStringList(conditions, 'conditions'),
      roots: toolStringList(roots, 'roots'),
      fallback: Array.from(fallback, entry => {
        if (!entry || typeof entry !== 'object' || typeof entry.name !== 'string' || entry.name.length === 0 ||
            (entry.target !== false && (typeof entry.target !== 'string' || entry.target.length === 0)) ||
            (entry.exact !== undefined && typeof entry.exact !== 'boolean')) {
          throw new TypeError('kessel: each fallback requires a name and a target string or false');
        }
        const ignore = entry.target === false;
        return { name: entry.name, target: ignore ? '' : entry.target, exact: entry.exact === true, ignore };
      }),
      restrictions: Array.from(restrictions, entry => {
        const keys = entry && typeof entry === 'object' ? Object.keys(entry) : [];
        if (keys.length !== 1 || (keys[0] !== 'path' && keys[0] !== 'regex') ||
            typeof entry[keys[0]] !== 'string' || entry[keys[0]].length === 0) {
          throw new TypeError('kessel: each restriction requires either a path or a regex string');
        }
        return { path: entry.path || '', regex: entry.regex || '' };
      }),
      fully_specified: fullySpecified === undefined ? null : fullySpecified,
      prefer_relative: preferRelative, prefer_absolute: preferAbsolute,
      resolve_to_context: resolveToContext, explicit_conditions: explicitConditions,
      typescript_references: tsconfigReferences,
      aliases: Array.from(aliases, alias => {
        if (!alias || typeof alias !== 'object' || typeof alias.name !== 'string' ||
            typeof alias.target !== 'string' || (alias.exact !== undefined && typeof alias.exact !== 'boolean')) {
          throw new TypeError('kessel: each alias requires a name and a target string');
        }
        return { name: alias.name, target: alias.target, exact: alias.exact === true };
      }),
    },
  };
}

function resolveModuleSync(specifier, importer, options = {}) {
  if (typeof specifier !== 'string' || typeof importer !== 'string') {
    throw new TypeError('kessel: specifier and importer must be strings');
  }
  const request = resolverOptions(options);
  const json = JSON.stringify({
    specifier, importer, require_mode: request.mode === 'require', options: request.options,
  });
  const value = readToolResult(_resolve_module, 'resolveModuleSync', toolInput(json, 'resolver request'));
  return { kind: value.kind.toLowerCase(), path: value.path };
}

function formatSync(filename, source, options = {}) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) {
    throw new TypeError('kessel: format options must be an object');
  }
  const { printWidth = 80, tabWidth = 2, useTabs = false, singleQuote = false,
    bracketSpacing = true, trailingComma = 'all', endOfLine = 'lf' } = options;
  if (!Number.isInteger(printWidth) || printWidth < 1 || printWidth > 0x7fffffff) {
    throw new RangeError('kessel: printWidth must be a positive 32-bit integer');
  }
  if (!Number.isInteger(tabWidth) || tabWidth < 0 || tabWidth > 16) {
    throw new RangeError('kessel: tabWidth must be an integer between 0 and 16');
  }
  if ([useTabs, singleQuote, bracketSpacing].some(value => typeof value !== 'boolean')) {
    throw new TypeError('kessel: useTabs, singleQuote and bracketSpacing must be booleans');
  }
  if (!['all', 'es5', 'none'].includes(trailingComma)) {
    throw new TypeError('kessel: trailingComma must be all, es5 or none');
  }
  if (!['lf', 'crlf', 'cr', 'auto'].includes(endOfLine)) {
    throw new TypeError('kessel: endOfLine must be lf, crlf, cr or auto');
  }
  const settings = { print_width: printWidth, tab_width: tabWidth, use_tabs: useTabs,
    single_quote: singleQuote, bracket_spacing: bracketSpacing, trailing_comma: trailingComma !== 'none', trailing_comma_es5: trailingComma === 'es5',
    end_of_line: endOfLine };
  return readToolResult(_format, 'formatSync', toolInput(filename, 'filename'),
    toolInput(source, 'source'), Buffer.from(JSON.stringify(settings)));
}

function isolatedDeclarationSync(filename, source) {
  return readToolResult(_isolated_declaration, 'isolatedDeclarationSync',
    toolInput(filename, 'filename'), toolInput(source, 'source'));
}

function transformSync(filename, source, options = {}) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) {
    throw new TypeError('kessel: transform options must be an object');
  }
  const { jsx = 'preserve', minified = false, sourceMap = false } = options;
  const { typescript = {}, explicitResourceManagement = false, define } = options;
  if (define !== undefined && (define === null || typeof define !== 'object' ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(define)) ||
      Object.values(define).some(value => typeof value !== 'string'))) {
    throw new TypeError('kessel: define must map names to JavaScript expression strings');
  }
  if (typeof explicitResourceManagement !== 'boolean') throw new TypeError('kessel: explicitResourceManagement must be a boolean');
  if (typescript === null || typeof typescript !== 'object' || Array.isArray(typescript)) {
    throw new TypeError('kessel: typescript options must be an object');
  }
  const { optimizeConstEnums = false } = typescript;
  if (typeof optimizeConstEnums !== 'boolean') throw new TypeError('kessel: optimizeConstEnums must be a boolean');
  const settingsObject = typeof jsx === 'object' && jsx !== null && !Array.isArray(jsx);
  const runtime = settingsObject ? jsx.runtime : jsx;
  if (runtime !== 'classic' && runtime !== 'automatic' && !(runtime === 'preserve' && !settingsObject)) {
    throw new TypeError('kessel: jsx must select preserve, classic, or automatic');
  }
  const { pragma, pragmaFrag, importSource, development = false, pure = true, throwIfNamespace = true } = settingsObject ? jsx : {};
  const lowering = transformLoweringSettings(options, settingsObject ? jsx.refresh : undefined);
  for (const value of [pragma, pragmaFrag, importSource]) {
    if (value !== undefined && (typeof value !== 'string' || value.length === 0)) {
      throw new TypeError('kessel: pragma, pragmaFrag, and importSource must be non-empty strings');
    }
  }
  if ([minified, sourceMap, development, pure, throwIfNamespace].some(value => typeof value !== 'boolean')) {
    throw new TypeError('kessel: minified, sourceMap, development, pure and throwIfNamespace must be booleans');
  }
  const settings = JSON.stringify({ define, jsx: runtime, pragma, pragma_frag: pragmaFrag, import_source: importSource,
    omit_pure: !pure, allow_namespaces: !throwIfNamespace, development, minified, source_map: sourceMap,
    optimize_const_enums: optimizeConstEnums, lower_using: explicitResourceManagement, ...lowering });
  return generatedCode(_transform, 'transformSync', filename, source, settings);
}

// Decorator, target and React Refresh options, validated and renamed for the native transformer.
function transformLoweringSettings(options, refresh = false) {
  const { target = 'esnext', decorator = {}, assumptions = {} } = options;
  if (assumptions === null || typeof assumptions !== 'object' || Array.isArray(assumptions)) {
    throw new TypeError('kessel: assumptions must be an object');
  }
  const { setPublicClassFields = false } = assumptions;
  if (typeof setPublicClassFields !== 'boolean') throw new TypeError('kessel: setPublicClassFields must be a boolean');
  if (typeof target !== 'string' || !/^(es6|es20(1[5-9]|2[0-4])|esnext)$/i.test(target)) {
    throw new TypeError('kessel: target must be a string from es2015 to es2024, or esnext');
  }
  if (decorator === null || typeof decorator !== 'object' || Array.isArray(decorator)) {
    throw new TypeError('kessel: decorator options must be an object');
  }
  const { legacy = false, emitDecoratorMetadata = false } = decorator;
  if (typeof legacy !== 'boolean' || typeof emitDecoratorMetadata !== 'boolean') {
    throw new TypeError('kessel: decorator.legacy and decorator.emitDecoratorMetadata must be booleans');
  }
  if (emitDecoratorMetadata && !legacy) throw new TypeError('kessel: emitDecoratorMetadata requires decorator.legacy');
  const refreshObject = typeof refresh === 'object' && refresh !== null && !Array.isArray(refresh);
  if (typeof refresh !== 'boolean' && !refreshObject) throw new TypeError('kessel: jsx.refresh must be a boolean or an object');
  const { refreshReg, refreshSig, emitFullSignatures = false } = refreshObject ? refresh : {};
  for (const value of [refreshReg, refreshSig]) {
    if (value !== undefined && (typeof value !== 'string' || value.length === 0)) {
      throw new TypeError('kessel: refreshReg and refreshSig must be non-empty strings');
    }
  }
  if (typeof emitFullSignatures !== 'boolean') throw new TypeError('kessel: emitFullSignatures must be a boolean');
  return { target, decorators: legacy ? 'legacy' : 'preserve', emit_decorator_metadata: emitDecoratorMetadata,
    class_fields: setPublicClassFields ? 'assign' : 'define',
    refresh: refresh !== false, refresh_reg: refreshReg, refresh_sig: refreshSig,
    refresh_full_signatures: emitFullSignatures };
}

function minifySync(filename, source, options = {}) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) {
    throw new TypeError('kessel: minify options must be an object');
  }
  const { compress = true, mangle = true, mangleNames = false, sourceMap = false, jsx = {} } = options;
  if (!jsx || typeof jsx !== 'object' || Array.isArray(jsx)) throw new TypeError('kessel: jsx must be an object');
  const { pragma, pragmaFrag } = jsx;
  if ([pragma, pragmaFrag].some(value => value !== undefined && (typeof value !== 'string' || !value.length))) {
    throw new TypeError('kessel: JSX pragma and pragmaFrag must be nonempty strings');
  }
  if ([compress, mangle, mangleNames, sourceMap].some(value => typeof value !== 'boolean')) {
    throw new TypeError('kessel: compress, mangle, mangleNames and sourceMap must be booleans');
  }
  return generatedCode(_minify, 'minifySync', filename, source,
    JSON.stringify({ compress, mangle, mangle_names: mangleNames, source_map: sourceMap, pragma, pragma_frag: pragmaFrag }));
}

function generatedCode(native, name, filename, source, settings) {
  const result = readToolResult(native, name, toolInput(filename, 'filename'),
    toolInput(source, 'source'), toolInput(settings, 'options'));
  return { code: result.output, map: result.map_json ? JSON.parse(result.map_json) : null, errors: result.errors || [] };
}

// Bundle the module graph that starts at `options.entry` and return the
// result in memory. Nothing is written; `outdir` only tells the source map
// where it will live so that its `sources` are relative to it.
function bundleSync(options) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) {
    throw new TypeError('kessel: bundle options must be an object');
  }
  const { entry, format = 'esm', platform = 'node', external = [], conditions = [], mainFields = [],
    tsconfig, globalName, outdir, minify = false, sourceMap = false, treeShaking = true,
    splitting = false, jsx = 'classic', define } = options;
  const entries = Array.isArray(entry) ? entry : [entry];
  if (entries.length === 0 || entries.some(item => typeof item !== 'string' || item.length === 0)) {
    throw new TypeError('kessel: entry must be a file path or a non-empty array of file paths');
  }
  if (!['esm', 'cjs', 'iife'].includes(format)) throw new TypeError('kessel: format must be esm, cjs or iife');
  if (!['node', 'browser'].includes(platform)) throw new TypeError('kessel: platform must be node or browser');
  for (const [name, list] of Object.entries({ external, conditions, mainFields })) {
    if (!Array.isArray(list) || list.some(item => typeof item !== 'string' || item.length === 0)) {
      throw new TypeError(`kessel: ${name} must be an array of non-empty strings`);
    }
  }
  for (const [name, value] of Object.entries({ tsconfig, globalName, outdir })) {
    if (value !== undefined && (typeof value !== 'string' || value.length === 0)) {
      throw new TypeError(`kessel: ${name} must be a non-empty string`);
    }
  }
  if ([minify, sourceMap, treeShaking, splitting].some(value => typeof value !== 'boolean')) {
    throw new TypeError('kessel: minify, sourceMap, treeShaking and splitting must be booleans');
  }
  if (define !== undefined && (define === null || typeof define !== 'object' ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(define)) ||
      Object.values(define).some(value => typeof value !== 'string'))) {
    throw new TypeError('kessel: define must map names to JavaScript expression strings');
  }
  const settingsObject = typeof jsx === 'object' && jsx !== null && !Array.isArray(jsx);
  const runtime = settingsObject ? (jsx.runtime ?? 'classic') : jsx;
  if (runtime !== 'classic' && runtime !== 'automatic') throw new TypeError('kessel: jsx must select classic or automatic');
  const { pragma, pragmaFrag, importSource, development = false } = settingsObject ? jsx : {};
  for (const value of [pragma, pragmaFrag, importSource]) {
    if (value !== undefined && (typeof value !== 'string' || value.length === 0)) {
      throw new TypeError('kessel: pragma, pragmaFrag, and importSource must be non-empty strings');
    }
  }
  if (typeof development !== 'boolean') throw new TypeError('kessel: jsx.development must be a boolean');
  const lowering = transformLoweringSettings(options);
  const request = JSON.stringify({
    entries: entries.map(item => path.resolve(item)), splitting, format, platform, externals: external, conditions, main_fields: mainFields,
    tsconfig, global_name: globalName, map_directory: outdir === undefined ? undefined : path.resolve(outdir),
    jsx: runtime, jsx_import_source: importSource, jsx_factory: pragma, jsx_fragment: pragmaFrag,
    jsx_development: development, define, target: lowering.target === 'esnext' ? '' : lowering.target,
    decorators: lowering.decorators === 'legacy' ? 'legacy' : '',
    emit_decorator_metadata: lowering.emit_decorator_metadata,
    minify, source_map: sourceMap, tree_shaking: treeShaking,
  });
  const reply = readToolResult(_bundle, 'bundleSync', toolInput(request, 'bundle options'));
  const diagnostics = (reply.diagnostics || []).map(item => ({
    severity: item.severity.toLowerCase(), file: item.path || null,
    line: item.line || null, column: item.line ? item.column : null, message: item.message,
  }));
  const outputs = (reply.outputs || []).map(file => ({
    fileName: file.name || null, code: file.code, map: file.map_json ? JSON.parse(file.map_json) : null, entry: file.entry,
  }));
  // A failed build has no outputs: the bundler never returns a partial bundle.
  const first = outputs[0] || { code: null, map: null };
  return { code: first.code, map: first.map, outputs,
    errors: diagnostics.filter(item => item.severity === 'error'),
    warnings: diagnostics.filter(item => item.severity === 'warning') };
}

module.exports = { parseSync, parseAsync, codegen, lintSync, scanModuleSync, parseRegExpSync, resolveModuleSync, formatSync, isolatedDeclarationSync, transformSync, minifySync, bundleSync };
