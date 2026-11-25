import { shared } from './shared.mjs';
console.log('lazy evaluated', shared.count);
export const value = 'lazy-value';
export default function () { return 'lazy-default'; }
