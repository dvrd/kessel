import { format } from './format.ts';
import { counter, bump } from './shared.ts';
import { extname } from 'node:path';
bump();
console.log('MARK_WORKER', format('warn', 'worker'), counter.n, extname('a.b'));
