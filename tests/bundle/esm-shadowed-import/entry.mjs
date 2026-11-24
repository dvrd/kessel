import { target } from './lib.mjs';
import { alias } from './lib.mjs';
function useParam(target$1) {
  // `value` is declared locally; the import below must not be captured by it.
  const value = 'local';
  return [target$1, value, alias()].join(',');
}
function outer() {
  const helper = 'outer-helper';
  return function inner(value) { return target() + helper + value; };
}
console.log(useParam('p'), outer()('!'));
