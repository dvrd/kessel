import { value as a, read as readA } from './a.mjs';
import { value as b, read as readB } from './b.mjs';
import helper from './a.mjs';
const value = 'entry';
function read() { return value; }
// The parameter shadows nothing that the bundle may rename onto it.
function shadow(value$1, helper$1) { return [value$1, helper$1, a, b, value].join('/'); }
console.log(a, b, value, readA(), readB(), read(), helper(), shadow('p', 'q'));
console.log(typeof console, typeof globalThis.process);
{
  const a = 'inner';
  console.log(a, b);
}
export { value, read };
