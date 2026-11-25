import { counter } from './state.mjs';
import { helper } from './page-helper.mjs';
counter.loads += 1;
console.log('page-a evaluated');
export const name = helper('a');
