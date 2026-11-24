import { register } from './registry.mjs';
register('late');
console.log('late evaluated');
export default 'late-default';
