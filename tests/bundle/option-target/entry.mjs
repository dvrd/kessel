import { pick } from './modern.mjs';
import legacy from './legacy.cjs';
const settings = { nested: { value: 0 }, list: null };
console.log(pick(settings), settings.list?.length ?? 'no list', 2 ** 10, legacy.spread({ a: 1 }, { b: 2 }));
let missing;
missing ??= 'assigned';
try { throw new Error('x'); } catch { console.log(missing); }
export const power = (base, exponent) => base ** exponent;
console.log(power(3, 3));
