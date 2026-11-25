console.log('b start');
import { shared, bump } from './shared.mjs';
import './only-b.mjs';
import cjs from './util.cjs';
bump();
console.log('b', shared.count, cjs.name);
export function later() { return import('./lazy.mjs').then(m => m.value); }
export default 'B';
