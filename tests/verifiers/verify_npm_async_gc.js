'use strict';

// parseAsync while the garbage collector runs.
//
// koffi hands a Buffer's memory to the native call without copying it, and an
// async call runs on a worker thread after parseAsync has returned. A buffer
// the call reads (source, file name, options) that nothing else references can
// be freed mid-call; the native side then reads garbage. This happened in CI:
// a TypeScript declaration file came back parsed as JavaScript. The test
// starts many async parses whose language comes only from the file name and
// options, collects garbage repeatedly while they are pending, and requires
// every one to parse exactly as parseSync does.
//
// Needs --expose-gc; `task test:npm:async-gc` passes it.

const assert = require('node:assert/strict');
const kessel = require('../../npm/kessel');

if (typeof global.gc !== 'function') throw new Error('run with node --expose-gc');

const ROUNDS = 150;
const CALLS = 64;
const source = 'declare type Decorator = <T extends Function>(target: T) => T | void;\n' +
  'declare const value: number;\ninterface Shape { readonly kind: "a" | "b"; }\n';
const expected = kessel.parseSync('lib.example.d.ts', source);
assert.deepEqual(expected.errors, []);

async function round(index) {
  const pending = [];
  for (let call = 0; call < CALLS; call++) {
    // A fresh file name string each time, so its buffer is never cached.
    pending.push(kessel.parseAsync('lib.example' + '.d.ts'.slice(0), source, {preserveParens: call % 2 === 0}));
    if (call % 8 === 0) global.gc();
  }
  for (let collect = 0; collect < 4; collect++) global.gc();
  const results = await Promise.all(pending);
  for (const result of results) {
    assert.deepEqual(result.errors, [], 'round ' + index);
    assert.equal(result.program.body.length, expected.program.body.length, 'round ' + index);
  }
}

(async () => {
  for (let index = 0; index < ROUNDS; index++) await round(index);
  console.log('parseAsync matched parseSync in ' + ROUNDS * CALLS + ' calls under repeated garbage collection.');
})().catch(error => { console.error(error); process.exit(1); });
