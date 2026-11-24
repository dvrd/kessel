console.log('entry start');
import { tag } from './eager.mjs';
import loader from './loader.cjs';
console.log(tag, loader.load().value, loader.load().value);
export { tag };
