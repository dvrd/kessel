// Load one module and print everything observable about it: what it logs
// while evaluating (in order), what it exports, or what it throws.
//
// Usage: node bundle_harness.mjs <esm|cjs|iife> <file> [--default] [--global=NAME]
//   --default      report the `default` export instead of the namespace (a
//                  CommonJS entry bundled to ESM exports its module.exports
//                  that way).
//   --global=NAME  for iife: report the global the bundle assigned.
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

const [kind, file, ...flags] = process.argv.slice(2);
const unwrapDefault = flags.includes('--default');
const globalName = (flags.find(flag => flag.startsWith('--global=')) || '').slice('--global='.length);

// Values are described structurally. Function names are left out because a
// bundler legitimately renames colliding bindings; fixtures that care about a
// name log it themselves.
function describe(value, depth = 0, seen = new Set()) {
  if (value === null) return 'null';
  switch (typeof value) {
    case 'undefined': return 'undefined';
    case 'string': return JSON.stringify(value);
    case 'number': return Object.is(value, -0) ? '-0' : String(value);
    case 'boolean': return String(value);
    case 'bigint': return value + 'n';
    case 'symbol': return value.toString();
    case 'function': return /^class\b/.test(Function.prototype.toString.call(value)) ? '[class]' : '[function]';
  }
  if (seen.has(value)) return '[circular]';
  if (depth > 3) return '[deep]';
  seen.add(value);
  let result;
  if (Array.isArray(value)) {
    result = '[' + value.map(item => describe(item, depth + 1, seen)).join(', ') + ']';
  } else if (value instanceof Error) {
    result = `[${value.name}: ${value.message}]`;
  } else {
    const keys = Object.keys(value).sort();
    result = '{' + keys.map(key => {
      let item;
      try { item = describe(value[key], depth + 1, seen); } catch (error) { item = `[throws ${error.name}: ${error.message}]`; }
      return JSON.stringify(key) + ': ' + item;
    }).join(', ') + '}';
  }
  seen.delete(value);
  return result;
}

function report(label, error) {
  const shown = error instanceof Error ? `${error.name}: ${error.message}` : describe(error);
  console.log(`${label} ${shown}`);
}

process.on('unhandledRejection', error => report('REJECTION', error));
process.on('uncaughtException', error => report('UNCAUGHT', error));

try {
  let exported;
  if (kind === 'esm') {
    exported = await import(pathToFileURL(file).href);
  } else if (kind === 'cjs') {
    exported = createRequire(import.meta.url)(file);
  } else {
    const context = vm.createContext({ console, setTimeout, queueMicrotask, Promise });
    vm.runInContext(readFileSync(file, 'utf8'), context, { filename: file });
    exported = globalName ? context[globalName] : undefined;
  }
  if (unwrapDefault && exported != null) exported = exported.default;
  // import() settles some microtasks after require() returns. Let pending
  // microtasks finish either way so the report lands at the same point.
  await new Promise(resolve => setImmediate(resolve));
  console.log('EXPORTS ' + describe(exported));
} catch (error) {
  report('THROWN', error);
}
