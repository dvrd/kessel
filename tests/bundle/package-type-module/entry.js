import { value } from './lib.js';
import legacy from './legacy/index.cjs';
import nested from './commonjs-dir/thing.js';
console.log(value, legacy.kind, nested.kind);
export default value;
