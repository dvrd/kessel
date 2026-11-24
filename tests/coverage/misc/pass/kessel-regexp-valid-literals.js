// Valid regexp literals that the lexer's validator rejected. The lexer now takes
// the regexp tree builder's verdict whenever the validator complains, so a
// complaint about a pattern the grammar accepts is dropped. V8 compiles each of
// these; the accept/reject table is tests/coverage/src/regex_literal_test.odin.
/[\&]/v;
/[a&&\&]/v;
/[[]]/v;
/[\q{\}}]/v;
/[\q{\u{1F600}}]/v;
/(?<a>a)\k<a>/;
/(?<\u0061>a)\k<a>/;
/[\!\#\%\,\:\;\<\=\>\@\~]/v;
/(?<=a){,2}/;
