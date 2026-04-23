// Lexical: unicode escape at identifier START position. `\u0061bc` must
// tokenise as the identifier `abc` (the escape decodes to U+0061 = 'a',
// which is a valid IdentifierStart). The declared variable name in the
// AST must be `abc`, not `\u0061bc`, because the cooked identifier name
// is what the binding is created under.
var \u0061bc = 1;
var \u{62}d = 2;
var \u0063_underscore = 3;
