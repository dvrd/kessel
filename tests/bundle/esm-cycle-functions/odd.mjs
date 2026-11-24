import { isEven } from './even.mjs';
// The cycle means even.mjs has not run yet, but its function is hoisted.
console.log('odd evaluated', isEven(4));
export function isOdd(n) { return n === 0 ? false : isEven(n - 1); }
