import * as all from './barrel.mjs';
import { one, two, shared, local } from './barrel.mjs';
console.log(Object.keys(all), one, two, shared, local, all.default);
export * from './barrel.mjs';
export { default } from './one.mjs';
