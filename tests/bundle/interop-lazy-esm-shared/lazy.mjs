// Required lazily by CommonJS: nothing here may run before load() is called.
import { shared } from './lazy-dep.mjs';
console.log('lazy evaluated');
export const value = 'lazy:' + shared;
