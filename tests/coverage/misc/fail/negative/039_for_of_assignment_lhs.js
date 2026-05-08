// ECMA-262 §14.7.5.1 — for-in/for-of LeftHandSideExpression must have a
// simple AssignmentTargetType. `a = 1` is an AssignmentExpression, not
// a LeftHandSideExpression, so `for (a = 1 of b)` fails. Unlike
// for-in, for-of has no Annex B.3.5 carve-out — `for (var a = 1 of
// b)` is a SyntaxError even in sloppy mode (and declarations would
// surface via parse_variable_declaration, not via this check).
for (a = 1 of b) {}
