// ECMA-262 §13.1 / §13.2.2 — a PrivateIdentifier (`#foo`) is only a
// valid Primary-position reference when it is the LHS of a `in`
// expression (`#foo in obj`). Using it in any other primary /
// assignment-target position outside a class body (or even inside
// one, when not preceded by `in`) is a SyntaxError.
var x = #foo;
