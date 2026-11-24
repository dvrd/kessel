import value, { fn, Base, key, tag, obj, list } from './lib.mjs';
import * as ns from './lib.mjs';
const shorthand = { value, fn, key };
const computed = { [key]: value, [`${key}2`]: fn() };
class Derived extends Base { field = value; static [key] = fn(); method(arg = value) { return arg; } }
const { [key]: picked = value } = { k: undefined };
const quoted = tag`a${value}b`;
function defaults(a = value, { b = fn() } = {}, ...rest) { return [a, b, rest.length]; }
label: for (const item of list) { if (item === value) continue label; console.log('item', item); }
console.log(JSON.stringify(shorthand), JSON.stringify(computed), new Derived().method(), Derived.k, picked, quoted);
console.log(defaults(), typeof value, value?.toString(), obj?.inner.fn(), obj.inner.fn.call(null), fn?.(), ns.fn(), new ns.Base().base);
console.log(typeof fn === 'function' ? fn`x` : null, [value, ...list], { ...obj }.inner === obj.inner, void value, delete obj.temp);
export const again = value;
