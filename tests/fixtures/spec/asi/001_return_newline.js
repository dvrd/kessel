// ECMA-262 \u00a712.10 \u2014 Restricted production: ReturnStatement. The argument
// is NOT recognised across a LineTerminator. `return\n1;` must parse as
// two statements: `return; 1;` not `return 1;`.
function f() {
  return
  1
}
