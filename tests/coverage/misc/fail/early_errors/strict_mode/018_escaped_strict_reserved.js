// ECMA-262 §12.7.2 + §13.2 — `let` is a FutureReservedWord reserved
// only in strict mode. In strict mode the escape-plus-ReservedWord
// rule applies: an IdentifierName with `\UnicodeEscapeSequence`
// whose StringValue equals "let" (or "static" / "yield" / etc.) is
// rejected as an Identifier.
//
// Sloppy-mode counterpart `var \u006Cet = 1;` parses fine because
// "let" isn't a reserved word in sloppy scripts.
'use strict';
var \u006Cet = 1;
