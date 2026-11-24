import { mode } from './mode.cjs';
import { flags } from './flags.ts';
// `process` is shadowed here, so this one is not the global and stays.
function local(process) { return process.env.NODE_ENV; }
console.log(process.env.NODE_ENV, mode, __VERSION__, typeof __DEV__, local({ env: { NODE_ENV: 'local' } }));
console.log(JSON.stringify(flags), globalThis.__VERSION__);
export const built = process.env.NODE_ENV === 'production' ? 'optimised' : 'debug';
