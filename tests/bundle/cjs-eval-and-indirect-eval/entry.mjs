import { viaEval } from './evaluates.cjs';
const indirect = (0, eval)('typeof globalThis');
const viaFunction = new Function('return 6 * 7')();
console.log(viaEval, indirect, viaFunction);
