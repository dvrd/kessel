// Lexical: U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) are
// recognised as LineTerminators by the spec. They MUST separate statements
// just as `\n` does, triggering ASI between them. If the lexer treats them
// as whitespace instead, the three `var` declarations below would be read
// as one malformed expression.
var a = 1 var b = 2 var c = a + b;
