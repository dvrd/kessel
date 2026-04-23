// Lexical: CRLF line endings combined with the `return` restricted
// production (ECMA-262 §12.10). A LineTerminator between `return`
// and an ArgumentExpression triggers ASI, so `return\r\n1` must parse as
// `return; 1;` (two statements) and NOT as `return 1;` (one statement).
// CRLF is counted as a single LineTerminator pair — it must not trip
// the parser into double-ASI or leave a stray empty statement.
function f() {
  return
  1
}
