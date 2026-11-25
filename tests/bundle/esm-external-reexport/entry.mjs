export * from 'node:path';
export { EventEmitter as Emitter, default as events } from 'node:events';
export * as os from 'node:os';
import { viaStar } from './star.mjs';
import { sep } from './star.mjs';
console.log(typeof viaStar, typeof sep);
