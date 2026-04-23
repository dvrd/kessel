// Interaction: `async function*` with a destructuring parameter that has
// default values at both the pattern and the whole-parameter level.
// Proves async-generator syntax coexists with nested destructuring
// (object-pattern-with-default inside a parameter-with-default-rhs) and
// with `yield` expressions in the body.
async function* g({ a, b = 1, nested: { c = 2 } = {} } = {}) {
  yield a;
  yield b;
  yield c;
}
