import { registry, register } from './registry.mjs';
import { tag } from './tag.cjs';
register('one');
console.log('one', registry.join(','), tag('1'));
export const size = () => registry.length;
