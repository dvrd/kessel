// ECMA-262 §14.7.5.1 — for-in/for-of LeftHandSideExpression must have a
// simple AssignmentTargetType. `a = 1` is an AssignmentExpression, not
// a LeftHandSideExpression, so `for (a = 1 in b)` fails. The same
// rule applies to for-of (fixture 039).
//
// Annex B.3.5 carves out a narrow exception: `for (var X = init in
// Expr) ...` is allowed in sloppy script for `var` declarations with
// an initializer — but that path reaches the parser as a
// VariableDeclaration (with the init on VariableDeclarator.init),
// NOT as an AssignmentExpression, so this check naturally bypasses
// it.
for (a = 1 in b) {}
