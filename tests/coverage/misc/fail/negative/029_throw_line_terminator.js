// ECMA-262 §14.14 Restricted Production — no LineTerminator is
// permitted between the `throw` keyword and its Expression argument.
// ASI does NOT rescue this; ASI cannot insert a semicolon where the
// grammar explicitly forbids it. `throw\nx;` is a SyntaxError.
throw
	x;
