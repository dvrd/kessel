// ECMA-262 §15.5 — plain (non-generator) function bodies don't
// introduce a yield context. `function f() { yield 1; }` is a
// SyntaxError even though the `yield 1;` form parses as a
// YieldExpression for recovery. Generators (`function* g()`) stay
// legal; this fixture pins the non-starred case.
function f() {
  return yield 1;
}
