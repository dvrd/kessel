// ECMA-262 §12.7.2 — "A code point in a ReservedWord cannot be expressed
// by a \UnicodeEscapeSequence." When an IdentifierName written with a
// Unicode escape has a StringValue that matches a ReservedWord, the
// narrower `Identifier : IdentifierName but not ReservedWord` production
// fails → Syntax Error.
//
// Here `\u0069f` cooks to "if"; using it as an IdentifierReference (at
// expression-start) is rejected. Other Identifier positions (binding,
// label) behave the same; IdentifierName positions (property access,
// property key, method name, import specifier) are unaffected.
\u0069f (x) y;
