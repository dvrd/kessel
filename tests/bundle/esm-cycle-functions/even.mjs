import { isOdd } from './odd.mjs';
console.log('even evaluated', typeof isOdd);
export function isEven(n) { return n === 0 ? true : isOdd(n - 1); }
