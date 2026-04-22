// ECMA-262 \u00a712.4 \u2014 Restricted production: PostfixExpression. No
// LineTerminator allowed before `++`/`--`. So `x\n++` parses as `x;`
// followed by a prefix `++` on the next statement (itself a SyntaxError
// or ExpressionStatement depending on what follows).
//
// Here we test the clean positive form: `x\n++ y` = `x;` + `++y;`.
let y = 1;
let x = 0
++y
