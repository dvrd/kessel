// Lexical: unicode escape at identifier CONTINUATION position. The first
// code unit is a plain IdentifierStart; subsequent escapes must decode to
// valid IdentifierContinue characters. The cooked names `abc`, `ab2`, and
// `a_b` are what show up in the AST.
var a\u0062c = 1;
var ab\u{32} = 2;
var a\u005fb = 3;
