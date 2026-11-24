import hoisted, { a } from './a.mjs';
console.log('b evaluated', hoisted());
try { console.log(a); } catch (error) { console.log(error.name); }
export const b = 'b-value';
export function callA() { return a; }
