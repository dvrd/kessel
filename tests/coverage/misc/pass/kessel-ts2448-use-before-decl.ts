// TS2448 — Block-scoped variable used before its declaration. Fires
// when a value-position Identifier reference resolves to a `let` /
// `const` / `using` declared LATER in the same block-scope region
// (Program / BlockStatement / FunctionBody / TSModuleBlock).
// Conservative: skips into nested function/arrow/method/class bodies
// (closures — refs are evaluated when called) and TS type positions.
function test() {
  fn();
  const fn = () => 1;
}
