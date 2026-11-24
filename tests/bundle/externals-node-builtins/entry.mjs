import path, { join } from 'node:path';
import * as os from 'os';
import inspector from 'node:inspector';
import { Session } from 'inspector';
import { helper } from './helper.cjs';
console.log(typeof inspector.url, typeof Session);
console.log(join('a', 'b') === path.join('a', 'b'), typeof os.platform(), helper('x/y.txt'));
export { join };
