import { version, describe } from './lib.mjs';
import Lib from './lib.mjs';
console.log('app', version, describe(), new Lib().name);
export const loaded = await import('./lib.mjs').then(lib => lib.version);
console.log(loaded);
