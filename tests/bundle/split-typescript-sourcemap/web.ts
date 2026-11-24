import { format, type Level } from './format.ts';
import * as shared from './shared.ts';
import path from 'node:path';
const level: Level = 'info';
console.log('MARK_WEB', format(level, 'web'), Object.keys(shared).join(','), shared.counter.n, path.basename('/x/y.z'));
export const view = (): Promise<string> => import('./view.ts').then(module => module.render('MARK_WEB_VIEW'));
console.log(await view());
