// Lexical: the mirror of the regex/comment case. When the preceding
// token could be followed by division (an Identifier, a literal, or a
// close-paren/bracket), a `/` after intervening comments must be parsed
// as division, not as the start of a regex literal.
const x = 10;
const a = x /* comment */ / 2;
const b = (x) /* comment */ / 3;
const c = x // line comment
  / 4;
