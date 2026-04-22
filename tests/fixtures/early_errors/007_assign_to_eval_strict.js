// ECMA-262 §13.15.1 — in strict mode, AssignmentExpression whose LHS
// directly references `eval` or `arguments` is a SyntaxError.
'use strict';
eval = 42;
