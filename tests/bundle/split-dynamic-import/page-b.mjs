import { counter } from './state.mjs';
import { helper } from './page-helper.mjs';
counter.loads += 1;
console.log('page-b evaluated');
export const name = helper('b');
