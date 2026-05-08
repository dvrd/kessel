// ECMA-262 §14.13.1 — a LabelledStatement whose LabelledItem is a
// FunctionDeclaration is a SyntaxError in strict mode. Allowed in
// sloppy script (Annex B.3.2 web-compat). The sloppy allowance is
// narrow: no async/generator, and not as a LabelledStatement inside
// an IfStatement; but the strict-mode ban is absolute.
'use strict';
foo: function bar() {}
