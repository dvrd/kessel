"use client";

import assert from "node:assert/strict";
import { events, acquire, observe } from "./observer.mjs";

using first = acquire("first"), second = acquire("second");
assert.equal(typeof liveFunction, "function");
assert.throws(() => early, ReferenceError);
assert.throws(() => readCycle(), ReferenceError);
export let early = 12;
export function liveFunction() { return early; }
export const getName = () => early;
export let named = class { static snapshot = this.name; };
export const [one, two = observe(), ...tail] = [1, undefined, 3, 4];
export const symbol = Symbol.for("detached");
const src = { [symbol]: 7, value: undefined, spare: 42, ["__proto__"]: true };
export const { [symbol]: field, value: fallback = () => one, ...rest } = src;
export class Example { static observed = events.slice(); }
export default class Published { static label = this.name; }
export { Published as AlsoPublished };
export { readCycle } from "./observer.mjs";
import { readCycle } from "./observer.mjs";
assert.equal(readCycle(), 12);
assert.equal(two, 1);
assert.equal(named.name, "named");
assert.equal(named.snapshot, "named");
assert.equal(fallback.name, "fallback");
assert.equal(fallback(), 1);
assert.equal(getName.name, "getName");
assert.deepEqual(tail, [3, 4]);
assert.equal(field, 7);
assert.equal(rest.spare, 42);
assert.ok(Object.hasOwn(rest, "__proto__"));
await using asynchronous = { async [Symbol.asyncDispose || Symbol.for("Symbol.asyncDispose")]() {
  events.push("async-start"); await 0; events.push("async-end");
} };
events.push("module-end");
early++;
