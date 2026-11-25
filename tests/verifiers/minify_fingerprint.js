'use strict';

// Load a script in a fresh context and describe everything it leaves behind:
// the global object and module.exports, walked through own properties and
// prototypes. Two programs with the same behavior at load time produce the
// same description. Function source text is never read, so a minified copy
// can be compared with its original.
const vm = require('node:vm');

const NODE_LIMIT = 20000;
const DEPTH_LIMIT = 5;

// Function names and error messages are wrapped in marker characters so one
// description serves every comparison: `loosen` removes what a renamed
// program may legitimately change.
const NAME = '\u0001', MESSAGE = '\u0002';

function loosen(text, loose) {
  let result = text;
  if (loose.names) result = result.replace(/\u0001[^\u0001]*\u0001/g, '');
  if (loose.messages) result = result.replace(/\u0002[^\u0002]*\u0002/g, '');
  return result;
}

function describe(value, out, seen, depth, label) {
  const type = value === null ? 'null' : typeof value;
  if (type !== 'object' && type !== 'function') {
    const text = type === 'symbol' ? value.toString() : Object.is(value, -0) ? '-0' : String(value);
    out.push(label + ' ' + type + ' ' + text.slice(0, 120).replace(/[\n\u0001\u0002]/g, ' '));
    return;
  }
  if (seen.has(value)) { out.push(label + ' seen#' + seen.get(value)); return; }
  seen.set(value, seen.size);
  let head = label + ' ' + type;
  if (type === 'function') {
    const length = Object.getOwnPropertyDescriptor(value, 'length');
    const name = Object.getOwnPropertyDescriptor(value, 'name');
    head += ' length=' + (length && length.value);
    head += NAME + ' name=' + (name && String(name.value)).replaceAll(NAME, '') + NAME;
  }
  let keys;
  try { keys = Reflect.ownKeys(value); } catch (error) { out.push(head + ' keys threw'); return; }
  out.push(head + ' keys=' + keys.length + (Object.isFrozen(value) ? ' frozen' : ''));
  if (depth >= DEPTH_LIMIT || out.length > NODE_LIMIT) return;
  for (const key of keys) {
    if (out.length > NODE_LIMIT) return;
    const shown = typeof key === 'symbol' ? key.toString() : key;
    if (type === 'function' && (key === 'length' || key === 'name' || key === 'arguments' || key === 'caller')) continue;
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor) continue;
    const flags = (descriptor.enumerable ? 'e' : '-') + (descriptor.configurable ? 'c' : '-') + (descriptor.writable ? 'w' : '-');
    const child = label + '.' + shown + '[' + flags + ']';
    // A stack records positions.
    if (key === 'stack') continue;
    // An engine message can quote a local name.
    if (key === 'message' && typeof descriptor.value === 'string') {
      out.push(child + ' string ' + MESSAGE + descriptor.value.slice(0, 120).replace(/[\n\u0002]/g, ' ') + MESSAGE);
      continue;
    }
    if ('value' in descriptor) describe(descriptor.value, out, seen, depth + 1, child);
    else out.push(child + ' accessor ' + (descriptor.get ? 'g' : '-') + (descriptor.set ? 's' : '-'));
  }
  const proto = Object.getPrototypeOf(value);
  if (proto !== null) describe(proto, out, seen, depth + 1, label + '.<proto>');
}

const CALL_LIMIT = 150;
const ARGUMENTS = [
  () => [], () => [1], () => ['ab', 'b'], () => [[3, 1, 2], x => x], () => [{ a: 1, b: [2] }, 'a'], () => [null, 2, 'c'],
];

// Call the functions a library exposes with a few fixed argument lists and
// describe what each call returns or throws. This runs code that loading
// alone never reaches.
function exercise(context, roots, out, seen) {
  const targets = [];
  const visited = new Set();
  const collect = (holder, label, depth) => {
    if (holder === null || (typeof holder !== 'object' && typeof holder !== 'function') || visited.has(holder)) return;
    visited.add(holder);
    let keys;
    try { keys = Object.keys(holder).sort(); } catch (error) { return; }
    for (const key of keys) {
      if (targets.length >= CALL_LIMIT) return;
      const descriptor = Object.getOwnPropertyDescriptor(holder, key);
      if (!descriptor || !('value' in descriptor)) continue;
      if (typeof descriptor.value === 'function') targets.push([holder, descriptor.value, label + '.' + key]);
      if (depth < 1) collect(descriptor.value, label + '.' + key, depth + 1);
    }
  };
  for (const [label, root] of roots) {
    if (typeof root === 'function') targets.push([undefined, root, label]);
    collect(root, label, 0);
  }
  for (const [holder, target, label] of targets) {
    ARGUMENTS.forEach((make, index) => {
      if (out.length > 3 * NODE_LIMIT) return;
      context.__kesselCall = { holder, target, args: make() };
      const call = label + '(#' + index + ')';
      try {
        const value = vm.runInContext('__kesselCall.target.apply(__kesselCall.holder, __kesselCall.args)', context, { timeout: 1000 });
        describe(value, out, new Map(seen), DEPTH_LIMIT - 2, call);
      } catch (error) {
        const timeout = error && error.code === 'ERR_SCRIPT_EXECUTION_TIMEOUT';
        // An error class declared by the library is renamed along with other functions.
        out.push(call + ' throw ' + (timeout ? 'timeout' : NAME + (error && error.constructor && error.constructor.name) + NAME));
      }
    });
  }
  delete context.__kesselCall;
}

// A called library function may start asynchronous work that later rejects.
let ignoringRejections = false;

// Compare two results with `loosen(text, { names, messages })`: `names` ignores
// function names and `messages` ignores error message text, for a program
// whose locals were renamed.
// A stand-in for the browser and for other modules: one object that answers every property read,
// call and construction with itself. It lets a library that touches
// `document` while loading finish loading, so its functions can be called.
// It is created inside the sandbox and behaves the same for both programs.
const DOM_STUB = `(() => {
  const any = new Proxy(function () {}, {
    get(target, key) {
      if (key === Symbol.toPrimitive) return () => '';
      if (key === Symbol.iterator) return function* () {};
      if (key === 'prototype') return target.prototype;
      if (key === 'then' || typeof key === 'symbol') return undefined;
      if (key === 'length' || key === 'nodeType') return key === 'length' ? 0 : 1;
      if (key === 'userAgent' || key === 'href' || key === 'readyState' || key === 'nodeName') return key === 'readyState' ? 'complete' : '';
      return any;
    },
    set() { return true; }, has() { return true; }, apply() { return any; }, construct() { return any; },
    ownKeys() { return ['prototype']; }, deleteProperty() { return true; },
  });
  for (const name of ['document', 'navigator', 'location', 'localStorage', 'sessionStorage', 'history', 'screen', 'getComputedStyle',
    'matchMedia', 'requestAnimationFrame', 'cancelAnimationFrame', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
    'addEventListener', 'removeEventListener', 'MutationObserver', 'ResizeObserver', 'IntersectionObserver', 'XMLHttpRequest', 'fetch',
    'Image', 'CustomEvent', 'Event', 'process', 'queueMicrotask', 'atob', 'btoa', 'URL', 'Headers', 'Request', 'Response',
    'Document', 'HTMLVideoElement', 'HTMLCanvasElement', 'HTMLImageElement']) globalThis[name] = any;
  // Most scripts that fail to load alone are CommonJS files asking for a sibling module.
  globalThis.require = () => any;
  for (const name of ['Node', 'Element', 'HTMLElement', 'SVGElement', 'DocumentFragment', 'EventTarget']) globalThis[name] = function () {};
})();`;

function fingerprint(code, calls = false) {
  const bare = fingerprintIn(code, calls, false);
  // A script that needs a browser or another module gets the stand-in on a second attempt.
  return bare.startsWith('throw ') ? 'dom\n' + fingerprintIn(code, calls, true) : bare;
}

// Whether a description is of a script that did not finish loading.
function threw(text) {
  return text.startsWith('dom\nthrow ');
}

function fingerprintIn(code, calls, dom) {
  if (calls && !ignoringRejections) {
    process.on('unhandledRejection', () => {});
    ignoringRejections = true;
  }
  const sandbox = { module: { exports: {} }, console: { log() {}, warn() {}, error() {}, info() {}, debug() {} } };
  sandbox.exports = sandbox.module.exports;
  const context = vm.createContext(sandbox);
  vm.runInContext('globalThis.window = globalThis.self = globalThis.global = globalThis;' +
    'Math.random = () => 0.25;' +
    'globalThis.Date = class extends Date { constructor(...args) { super(...(args.length ? args : [1700000000000])); }' +
    ' static now() { return 1700000000000; } };' +
    'if (globalThis.performance) performance.now = () => 5;' +
    'globalThis.require = name => { throw new Error("no module " + name); };' + (dom ? DOM_STUB : ''), context);
  const baseline = new Map();
  // Built-ins that exist before the script runs are identical on both sides.
  for (const key of Reflect.ownKeys(context)) baseline.set(context[key], baseline.size);
  const out = [];
  try {
    const completion = vm.runInContext(code, context, { timeout: 20000 });
    describe(completion, out, new Map(baseline), 0, 'completion');
  } catch (error) {
    const name = error && error.constructor && error.constructor.name;
    // A message can quote a local name, which mangling legitimately changes.
    out.push('throw ' + NAME + name + NAME + MESSAGE + ' ' + String(error && error.message).slice(0, 200).replace(/[\n\u0002]/g, ' ') + MESSAGE);
  }
  const seen = new Map(baseline);
  const roots = [];
  for (const key of Reflect.ownKeys(context)) {
    if (baseline.has(context[key]) && key !== 'module' && key !== 'exports') continue;
    describe(context[key], out, seen, 0, String(key));
    if (key !== 'module' && key !== 'exports') roots.push([String(key), context[key]]);
  }
  describe(sandbox.module.exports, out, seen, 0, 'module.exports');
  roots.push(['module.exports', sandbox.module.exports]);
  if (calls) exercise(context, roots, out, seen);
  return out.join('\n');
}

// A module that did not finish loading, as described by minify_module_runner.mjs.
function moduleThrew(text) {
  return text.startsWith('throw ');
}

module.exports = { fingerprint, loosen, threw, moduleThrew, describe, exercise, NAME, MESSAGE };
