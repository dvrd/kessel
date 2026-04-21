// Trailing commas en diferentes posiciones
const arr = [1, 2, 3,];
const obj = {
  a: 1,
  b: 2,
};

function test(a, b, c,) {
  return a + b + c;
}

const fn = (x, y,) => x + y;

import { a, b, } from 'module';
export { x, y, };

const nested = {
  arr: [1, 2,],
  obj: { a: 1, },
};
