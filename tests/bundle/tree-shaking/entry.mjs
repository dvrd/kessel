import { used, chained } from './lib.mjs';
import { alsoUsed } from './barrel.mjs';
import './effects.mjs';
console.log(used(), chained(), alsoUsed);
