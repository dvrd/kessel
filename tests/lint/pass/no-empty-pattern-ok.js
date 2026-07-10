// no-empty-pattern (L2015) passing: non-empty patterns and empty *object
// literals* used as defaults are fine (`{}` after `=` is a default value, not
// a pattern).
const { a, b } = require("x");
function draw({ size = 1, position = {} }) {
  return size + position.x;
}
const [first, ...rest] = [1, 2, 3];
