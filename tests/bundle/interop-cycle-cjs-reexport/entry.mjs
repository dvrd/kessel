// b.mjs runs before c.cjs is loaded and reads its exports through a.mjs.
// Node gives it `undefined` for each of them, not an error.
import { later } from './b.mjs';
import { x } from './a.mjs';
console.log('entry', x);
console.log(later().join(','));
