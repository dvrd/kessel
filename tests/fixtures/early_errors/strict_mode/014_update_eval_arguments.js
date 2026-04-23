// ECMA-262 §13.4.1 — in strict mode, the operand of an UpdateExpression
// must not be an IdentifierReference named `eval` or `arguments`.
// Covers prefix AND postfix forms. Sloppy script allows both.
'use strict';
eval++;
arguments--;
++eval;
--arguments;
