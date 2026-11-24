import path, { join } from 'node:path';
import * as os from 'os';
import { helper } from './helper.cjs';
console.log(join('a', 'b') === path.join('a', 'b'), typeof os.platform(), helper('x/y.txt'));
export { join };
