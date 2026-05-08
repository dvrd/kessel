// ECMA-262 §12.5.1.1 — `delete` of an unqualified IdentifierReference
// is a SyntaxError in strict mode. `delete x.y` and `delete x[y]` are
// still legal; the rule only forbids the bare identifier form.
'use strict';
var x = 1;
delete x;
