import assert from 'node:assert/strict';

const events = [];
const dispose = Symbol.dispose || Symbol.for('Symbol.dispose');
const asyncDispose = Symbol.asyncDispose || Symbol.for('Symbol.asyncDispose');

function resource(id) {
  const object = {
    id,
    get [dispose]() {
      events.push('lookup:' + id);
      return function () {
        assert.equal(this, object);
        events.push('close:' + id);
      };
    }
  };
  return object;
}
function fail(value) {
  return { [dispose]() { throw value; } };
}
function nested() {
  'use strict';
  using first = resource('a'), second = resource('b');
  try {
    using inner = resource('c');
    events.push('body');
    return this;
  } finally {
    events.push('finally');
  }
}
assert.equal(nested(), undefined);
assert.deepEqual(events.splice(0), ['lookup:a', 'lookup:b', 'lookup:c', 'body', 'close:c', 'finally', 'close:b', 'close:a']);
let suppressed;
try {
  using first = fail('first'), second = fail('second');
  throw undefined;
} catch (error) { suppressed = error; }
assert.equal(suppressed.name, 'SuppressedError');
assert.equal(suppressed.error, 'first');
assert.equal(suppressed.suppressed.error, 'second');
assert.equal(suppressed.suppressed.suppressed, undefined);
function partial() {
  using first = resource('ok'), invalid = 123;
}
assert.throws(partial, TypeError);
assert.deepEqual(events.splice(0), ['lookup:ok', 'close:ok']);
class Owner {
  static { using field = resource('static'); events.push('init'); }
}
assert.deepEqual(events.splice(0), ['lookup:static', 'init', 'close:static']);
function* paused() {
  using held = resource('gen');
  yield 'waiting';
}
const generator = paused();
assert.equal(generator.next().value, 'waiting');
generator.return();
assert.deepEqual(events.splice(0), ['lookup:gen', 'close:gen']);
{
  Object.defineProperty(Function.prototype, dispose, { configurable: true, value() { events.push(typeof this.name === 'string' ? this.name : this.name()); } });
  try {
    using named = class { static label = this.name; };
    assert.equal(named.label, 'named');
    {
      using __proto__ = class { static label = this.name; };
      assert.equal(__proto__.label, '__proto__');
    }
    {
      using __proto__ = class { static ['name']() { return 'chosen'; } };
      assert.equal(__proto__.name(), 'chosen');
    }
    using hasName = class { static name() { return 'method'; } };
    assert.equal(hasName.name(), 'method');
  } finally { delete Function.prototype[dispose]; }
  assert.deepEqual(events.splice(0), ['__proto__', 'chosen', 'method', 'named']);
}
const arrow = () => { using r = resource('arrow'); return () => r.id; };
assert.equal(arrow()(), 'arrow');
assert.deepEqual(events.splice(0), ['lookup:arrow', 'close:arrow']);

outer: for (using item of [resource('one'), resource('two')]) {
  events.push(item.id);
  if (item.id === 'one') continue outer;
  break;
}
assert.deepEqual(events.splice(0), ['lookup:one', 'one', 'close:one', 'lookup:two', 'two', 'close:two']);
let rounds = 0;
a: b: for (using once = resource('head'); rounds < 2; rounds++) {
  events.push(once.id);
  continue a;
}
assert.deepEqual(events.splice(0), ['lookup:head', 'head', 'head', 'close:head']);
async function asynchronous() {
  using first = resource('end');
  await using ignored = null;
  await using sync = { [dispose]() { events.push('sync-fallback'); return { then() { throw Error('unexpected then'); } }; } };
  await using last = { async [asyncDispose]() { events.push('async'); await 0; events.push('awaited'); } };
  return 42;
}
const result = asynchronous();
assert.deepEqual(events.splice(0), ['lookup:end', 'async']);
assert.equal(await result, 42);
assert.deepEqual(events.splice(0), ['awaited', 'sync-fallback', 'close:end']);
async function empty() {
  using early = resource('early');
  await using later = null;
}
const emptyResult = empty();
assert.deepEqual(events.splice(0), ['lookup:early']);
await emptyResult;
assert.deepEqual(events.splice(0), ['close:early']);
console.log('resource lifetimes passed');
