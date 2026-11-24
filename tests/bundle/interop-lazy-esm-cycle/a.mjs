import { b, callA } from './b.mjs';
console.log('a evaluated', b);
export const a = 'a-value';
export function readB() { return b + callA(); }
export default function hoisted() { return 'hoisted-a'; }
