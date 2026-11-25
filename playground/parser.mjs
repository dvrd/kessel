// WASI Preview 1 process with no arguments or open file descriptors. Parsing
// reads source directly from linear memory. Odin uses random_get for hash seeds.
function startInstance(module) {
  let api;
  const badFile = () => 8; // WASI errno.badf
  const wasi = {
    args_sizes_get(count, size) {
      const view = new DataView(api.memory.buffer);
      view.setUint32(count, 0, true);
      view.setUint32(size, 0, true);
      return 0;
    },
    args_get: () => 0,
    random_get(address, length) {
      const bytes = new Uint8Array(api.memory.buffer, address >>> 0, length >>> 0);
      // Web Crypto limits each call to 65,536 bytes.
      for (let start = 0; start < bytes.length; start += 65536) {
        globalThis.crypto.getRandomValues(bytes.subarray(start, start + 65536));
      }
      return 0;
    },
    fd_prestat_get: badFile, fd_prestat_dir_name: badFile, fd_filestat_get: badFile,
    fd_read: badFile, fd_pread: badFile, fd_write: badFile, fd_pwrite: badFile,
    fd_seek: badFile, fd_sync: badFile, fd_close: badFile,
  };
  // The module has no math library. Constant folding of `**` asks the host,
  // whose answer is by definition what the folded code would have computed.
  const env = { pow: Math.pow };
  api = new WebAssembly.Instance(module, { wasi_snapshot_preview1: wasi, env }).exports;
  api._start();
  return api;
}

const languages = ['js', 'jsx', 'ts', 'tsx'];
const lintLevels = new Map([
  [0, 'off'], [1, 'warn'], [2, 'error'], ['allow', 'off'], ['deny', 'error'],
  ['off', 'off'], ['warn', 'warn'], ['error', 'error'],
]);
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });

function plainObject(value, name) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError('Expected ' + name);
  }
  return value;
}

function requireBooleans(options) {
  for (const [name, value] of Object.entries(options)) {
    if (typeof value !== 'boolean') throw new TypeError(name + ' must be boolean');
  }
}

// Rule settings in the form the native linter reads: `name:level` lines, or
// one JSON object as soon as a rule carries options.
function ruleSettings(rules) {
  if (rules === undefined) return '';
  const settings = {};
  let structured = false;
  for (const [name, value] of Object.entries(plainObject(rules, 'a rules object'))) {
    const level = Array.isArray(value) ? value[0] : value;
    if (!lintLevels.has(level) || /[:\n]/.test(name)) {
      throw new TypeError('Invalid lint setting for ' + name);
    }
    if (Array.isArray(value) && value.length > 1) {
      structured = true;
      settings[name] = [lintLevels.get(level), ...value.slice(1)];
    } else {
      settings[name] = lintLevels.get(level);
    }
  }
  if (structured) return JSON.stringify(settings);
  return Object.entries(settings).map(([name, level]) => name + ':' + level).join('\n');
}

// Byte offsets where lines begin. Diagnostic offsets and columns count UTF-8
// bytes, as they do in the CLI and the Node bindings. CRLF is one break and
// the Unicode line and paragraph separators end a line.
function lineStarts(bytes) {
  const starts = [0];
  for (let index = 0; index < bytes.length; index++) {
    const byte = bytes[index];
    if (byte === 0x0d) {
      if (bytes[index + 1] === 0x0a) index++;
    } else if (byte === 0xe2 && bytes[index + 1] === 0x80 &&
        (bytes[index + 2] === 0xa8 || bytes[index + 2] === 0xa9)) {
      index += 2;
    } else if (byte !== 0x0a) {
      continue;
    }
    starts.push(index + 1);
  }
  return starts;
}

// The 1-based line and column of a byte offset.
function locate(starts, offset) {
  let low = 0, high = starts.length - 1;
  while (low < high) {
    const middle = (low + high + 1) >>> 1;
    if (starts[middle] <= offset) low = middle;
    else high = middle - 1;
  }
  return [low + 1, offset - starts[low] + 1];
}

// Add `line`, `column`, `endLine` and `endColumn` to byte spans.
function withPositions(spans, bytes) {
  if (spans.length === 0) return spans;
  const starts = lineStarts(bytes);
  for (const span of spans) {
    [span.line, span.column] = locate(starts, span.start);
    [span.endLine, span.endColumn] = locate(starts, span.end);
  }
  return spans;
}

function toolError(value) {
  const ErrorType = value.code === 'Invalid_Syntax' ? SyntaxError : Error;
  const error = new ErrorType(value.message);
  error.code = value.code;
  if (value.offset !== null && value.offset !== undefined) error.offset = value.offset;
  return error;
}

function formatSettings(options) {
  const {
    language = 'js', printWidth = 80, tabWidth = 2, useTabs = false, singleQuote = false,
    bracketSpacing = true, trailingComma = 'all', endOfLine = 'lf',
  } = plainObject(options, 'format options');
  if (!Number.isInteger(printWidth) || printWidth < 1 || printWidth > 2147483647) {
    throw new RangeError('Invalid printWidth');
  }
  if (!Number.isInteger(tabWidth) || tabWidth < 0 || tabWidth > 16) {
    throw new RangeError('Invalid tabWidth');
  }
  if ([useTabs, singleQuote, bracketSpacing].some(value => typeof value !== 'boolean')) {
    throw new TypeError('Expected boolean formatter options');
  }
  if (!['all', 'es5', 'none'].includes(trailingComma)) throw new TypeError('Invalid trailingComma');
  const ending = ['lf', 'crlf', 'cr', 'auto'].indexOf(endOfLine);
  if (ending < 0) throw new TypeError('Invalid endOfLine');
  return {
    language, printWidth, tabWidth, useTabs, singleQuote, bracketSpacing,
    trailing: trailingComma !== 'none', ending,
  };
}

// Validated transform options under the names the native transformer reads.
function transformSettings(options) {
  const {
    language = 'ts', jsx = 'preserve', target = 'esnext', minified = false, development = false,
    importSource, pragma, pragmaFrag, legacyDecorators = false, refresh = false,
  } = plainObject(options, 'transform options');
  if (!['preserve', 'classic', 'automatic'].includes(jsx)) {
    throw new TypeError('jsx must be preserve, classic or automatic');
  }
  if (typeof target !== 'string' || !/^(es6|es20(1[5-9]|2[0-4])|esnext)$/i.test(target)) {
    throw new TypeError('target must be es2015 to es2024, or esnext');
  }
  requireBooleans({ minified, development, legacyDecorators, refresh });
  for (const value of [importSource, pragma, pragmaFrag]) {
    if (value !== undefined && (typeof value !== 'string' || value.length === 0)) {
      throw new TypeError('importSource, pragma and pragmaFrag must be non-empty strings');
    }
  }
  return {
    language,
    settings: {
      jsx, target, minified, development, import_source: importSource, pragma,
      pragma_frag: pragmaFrag, decorators: legacyDecorators ? 'legacy' : 'preserve', refresh,
    },
  };
}

/**
 * Create a synchronous, reusable toolchain from the compiled Kessel module.
 * Every method takes the source text and an options object whose `language`
 * is `js`, `jsx`, `ts` or `tsx`. Offsets, lines and columns in results count
 * UTF-8 bytes, like the CLI and the Node bindings.
 */
export function createParser(module) {
  let api = startInstance(module);
  const inputLimit = api.input_limit();
  const optionsLimit = api.options_limit();

  // Copy the source, and the options text when the tool takes any, into the
  // module, run one export and decode its JSON reply. `bytes` is a copy of
  // the encoded source for the caller to compute positions from.
  function invoke(source, language, settings, run) {
    if (typeof source !== 'string') throw new TypeError('Source must be a string');
    const index = languages.indexOf(language);
    if (index < 0) throw new TypeError('Language must be js, jsx, ts or tsx');
    const tooLarge = () =>
      new RangeError('Source exceeds the ' + inputLimit + '-byte playground limit');
    if (source.length > inputLimit) throw tooLarge();
    // A trap can interrupt arena cleanup. Create fresh linear memory on the next call.
    api ??= startInstance(module);
    const input = new Uint8Array(api.memory.buffer, api.input_address(), inputLimit);
    const { read, written } = encoder.encodeInto(source, input);
    if (read !== source.length) throw tooLarge();
    const bytes = input.slice(0, written);
    const options = new Uint8Array(api.memory.buffer, api.options_address(), optionsLimit);
    const encoded = encoder.encodeInto(settings, options);
    if (encoded.read !== settings.length) {
      throw new RangeError('Options exceed the ' + optionsLimit + '-byte playground limit');
    }
    try {
      const size = run(api, written, index, encoded.written);
      if (!size) throw new Error('Could not allocate memory to process this input');
      // Processing may grow memory and invalidate the old ArrayBuffer.
      const output = new Uint8Array(api.memory.buffer, api.output_address(), size);
      return { value: JSON.parse(decoder.decode(output)), bytes };
    } catch (error) {
      api = undefined;
      throw error;
    }
  }

  // Tools that print code answer with `output` and `errors`. Exactly one of
  // the two is filled in.
  function generated(source, language, settings, run) {
    const { value, bytes } = invoke(source, language, JSON.stringify(settings), run);
    if (typeof value.code === 'string') throw toolError(value);
    return { code: value.output ?? '', errors: withPositions(value.errors ?? [], bytes) };
  }

  return {
    inputLimit,
    optionsLimit,
    /** ESTree JSON as the CLI prints it, with `errors` when there are any. */
    parse(source, { language = 'js', semanticErrors = false } = {}) {
      if (typeof semanticErrors !== 'boolean') throw new TypeError('semanticErrors must be boolean');
      return invoke(source, language, '', (api, length, index) =>
        api.parse_source(length, index, Number(semanticErrors))).value;
    },
    /** Formatted source. Throws a SyntaxError when the source does not parse. */
    format(source, options = {}) {
      const { language, printWidth, tabWidth, useTabs, singleQuote, bracketSpacing, trailing,
        ending } = formatSettings(options);
      const { value } = invoke(source, language, '', (api, length, index) =>
        api.format_source(length, index, printWidth, tabWidth, useTabs, singleQuote,
          bracketSpacing, trailing, ending));
      if (typeof value === 'string') return value;
      throw toolError(value);
    },
    /**
     * Diagnostics from the default rules, or from `rules`, which maps a rule
     * name (plugin-qualified names such as `unicorn/no-thenable` included) to
     * `off`, `warn`, `error` or `[level, options]`. Parser diagnostics come
     * first and have a `K` code and no `rule`.
     */
    lint(source, options = {}) {
      const { language = 'js', rules } = plainObject(options, 'lint options');
      const { value, bytes } = invoke(source, language, ruleSettings(rules),
        (api, length, index, size) => api.lint_source(length, index, size));
      if (typeof value.code === 'string') throw toolError(value);
      return { diagnostics: withPositions(value.diagnostics ?? [], bytes) };
    },
    /**
     * TypeScript and JSX lowered to JavaScript: `jsx` is `preserve`,
     * `classic` or `automatic` and `target` is `es2015` to `es2024` or
     * `esnext`. Returns `{ code, errors }`.
     */
    transform(source, options = {}) {
      const { language, settings } = transformSettings(options);
      return generated(source, language, settings, (api, length, index, size) =>
        api.transform_source(length, index, size));
    },
    /** Minified source as `{ code, errors }`. */
    minify(source, options = {}) {
      const { language = 'js', compress = true, mangle = true, mangleNames = false } =
        plainObject(options, 'minify options');
      requireBooleans({ compress, mangle, mangleNames });
      const settings = { compress, mangle, mangle_names: mangleNames };
      return generated(source, language, settings, (api, length, index, size) =>
        api.minify_source(length, index, size));
    },
    /** The isolated declaration file of a TypeScript source as `{ code, errors }`. */
    declaration(source, options = {}) {
      const { language = 'ts' } = plainObject(options, 'declaration options');
      const { value, bytes } = invoke(source, language, '', (api, length, index) =>
        api.declaration_source(length, index));
      return { code: value.output ?? '', errors: withPositions(value.errors ?? [], bytes) };
    },
  };
}
