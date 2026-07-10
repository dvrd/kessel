// no-empty-pattern (L2015): empty destructuring patterns bind nothing.
const {} = require("x");
function draw({ size = 1, position: [] }) {
  return size;
}
