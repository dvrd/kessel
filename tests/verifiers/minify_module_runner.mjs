// Load one ES module with dynamic import() and describe what it exports, the
// globals it leaves behind and, with --calls, what its exported functions
// return for a few fixed argument lists. verify_minify.js runs this once per
// program in a fresh Node process and compares the descriptions of a module
// and its minified forms, as minify_fingerprint.js does for scripts.
//
//   node minify_module_runner.mjs <file.mjs> [--calls]
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const { describe, exercise, NAME, MESSAGE } = require('./minify_fingerprint.js');
const [file, ...flags] = process.argv.slice(2);
const write = process.stdout.write.bind(process.stdout);

// The same pinned clock and random numbers as the script sandbox, and no output of the module's own.
Math.random = () => 0.25;
const RealDate = Date;
globalThis.Date = class extends RealDate {
  constructor(...args) { super(...(args.length ? args : [1700000000000])); }
  static now() { return 1700000000000; }
};
performance.now = () => 5;
for (const method of ['log', 'warn', 'error', 'info', 'debug', 'trace']) console[method] = () => {};
process.stdout.write = () => true;
process.stderr.write = () => true;
process.on('unhandledRejection', () => {});
process.on('uncaughtException', () => {});

const baseline = new Map();
for (const key of Reflect.ownKeys(globalThis)) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, key);
  if (descriptor && 'value' in descriptor) baseline.set(descriptor.value, baseline.size);
}
const before = new Set(Reflect.ownKeys(globalThis));
const out = [];
let namespace = null;
try {
  namespace = await import(pathToFileURL(file).href);
} catch (error) {
  const name = error && error.constructor && error.constructor.name;
  // The message of a failed import names the file, which differs between the copies.
  const text = String(error && error.message).replaceAll(file, '<file>').replaceAll(pathToFileURL(file).href, '<file>');
  out.push('throw ' + NAME + name + NAME + MESSAGE + ' ' + text.slice(0, 200).replace(/[\n\u0002]/g, ' ') + MESSAGE);
}
const seen = new Map(baseline);
const roots = [];
for (const key of Reflect.ownKeys(globalThis)) {
  if (before.has(key)) continue;
  describe(globalThis[key], out, seen, 0, 'global ' + String(key));
  roots.push(['global ' + String(key), globalThis[key]]);
}
if (namespace !== null) {
  describe(namespace, out, seen, 0, 'exports');
  roots.push(['exports', namespace]);
  if (flags.includes('--calls')) exercise(vm.createContext({}), roots, out, seen);
}
write(out.join('\n'), () => process.exit(0));
