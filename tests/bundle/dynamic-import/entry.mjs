console.log('entry');
import { eager } from './eager.mjs';
const lazy = import('./lazy.mjs');
console.log('after import() call', eager);
const ns = await lazy;
console.log(Object.keys(ns), ns.default, ns.value, (await import('./lazy.mjs')) === ns);
const cjs = await import('./lazy.cjs');
console.log(cjs.default.kind, cjs.kind);
try { await import('./throws.mjs'); } catch (error) { console.log('caught', error.message); }
// An ES module that failed stays failed with the same error.
try { await import('./throws.mjs'); } catch (error) { console.log('caught', error.message); }
export const done = true;
