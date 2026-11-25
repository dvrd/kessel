console.log('entry');
import { counter } from './state.mjs';
const [a, b] = await Promise.all([import('./page-a.mjs'), import('./page-b.mjs')]);
console.log(a.name, b.name, counter.loads, (await import('./page-a.mjs')) === a);
const legacy = await import('./legacy.cjs');
console.log(legacy.default.kind, legacy.kind);
try { await import('./broken.mjs'); } catch (error) { console.log('caught', error.message); }
export const done = counter.loads;
