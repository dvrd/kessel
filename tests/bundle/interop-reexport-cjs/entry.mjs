export { named, other as renamed } from './lib.cjs';
export { default } from './lib.cjs';
export { default as viaEsm, named as viaEsmNamed } from './middle.mjs';
import * as middle from './middle.mjs';
console.log(Object.keys(middle), middle.viaStar, middle.default.named);
