import { helper } from './dep.mjs';
console.log('lib evaluated', helper());
export let count = 0;
export function bump() { count += 1; }
export const named = 'named-export';
export default 'default-export';
