console.log('entry start');
import { helper } from './helper.mjs';
console.log(helper());
const self = await import('./entry.mjs');
console.log('self import resolved', typeof self);
