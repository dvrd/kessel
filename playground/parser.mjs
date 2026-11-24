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
  api = new WebAssembly.Instance(module, { wasi_snapshot_preview1: wasi }).exports;
  api._start();
  return api;
}

const languages = ['js', 'jsx', 'ts', 'tsx'];
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });

/** Create a synchronous, reusable ESTree parser from the compiled Kessel module. */
export function createParser(module) {
  let api = startInstance(module);
  const inputLimit = api.input_limit();
  function invoke(source, language, run) {
    if (typeof source !== 'string') throw new TypeError('Source must be a string');
    const index = languages.indexOf(language);
    if (index < 0) throw new TypeError('Language must be js, jsx, ts or tsx');
    const tooLarge = () => new RangeError('Source exceeds the ' + inputLimit + '-byte playground limit');
    if (source.length > inputLimit) throw tooLarge();
    // A trap can interrupt arena cleanup. Create fresh linear memory on the next call.
    api ??= startInstance(module);
    const input = new Uint8Array(api.memory.buffer, api.input_address(), inputLimit);
    const {read, written} = encoder.encodeInto(source, input);
    if (read !== source.length) throw tooLarge();
    try {
      const size = run(api, written, index);
      if (!size) throw new Error('Could not allocate memory to process this input');
      // Processing may grow memory and invalidate the old ArrayBuffer.
      const output = new Uint8Array(api.memory.buffer, api.output_address(), size);
      return JSON.parse(decoder.decode(output));
    } catch (error) {
      api = undefined;
      throw error;
    }
  }

  return {
    inputLimit,
    parse(source, {language = 'js', semanticErrors = false} = {}) {
      if (typeof semanticErrors !== 'boolean') throw new TypeError('semanticErrors must be boolean');
      return invoke(source, language, (api, length, index) => api.parse_source(length, index, Number(semanticErrors)));
    },
    format(source, options = {}) {
      if (!options || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('Expected format options');
      const {language = 'js', printWidth = 80, tabWidth = 2, useTabs = false, singleQuote = false,
        bracketSpacing = true, trailingComma = 'all', endOfLine = 'lf'} = options;
      if (!Number.isInteger(printWidth) || printWidth < 1 || printWidth > 2147483647) throw new RangeError('Invalid printWidth');
      if (!Number.isInteger(tabWidth) || tabWidth < 0 || tabWidth > 16) throw new RangeError('Invalid tabWidth');
      if ([useTabs, singleQuote, bracketSpacing].some(value => typeof value !== 'boolean')) throw new TypeError('Expected boolean formatter options');
      if (!['all', 'es5', 'none'].includes(trailingComma)) throw new TypeError('Invalid trailingComma');
      const ending = ['lf', 'crlf', 'cr', 'auto'].indexOf(endOfLine);
      if (ending < 0) throw new TypeError('Invalid endOfLine');
      const value = invoke(source, language, (api, length, index) =>
        api.format_source(length, index, printWidth, tabWidth, useTabs, singleQuote, bracketSpacing, trailingComma !== 'none', ending));
      if (typeof value === 'string') return value;
      const error = new SyntaxError(value.message);
      error.code = value.code;
      error.offset = value.offset;
      throw error;
    },
  };
}
