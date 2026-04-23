// Lexical: at the boundary between a comment and a following `/`, the
// tokeniser's regex-vs-division state must be preserved ACROSS the
// comment. A block comment is whitespace for the grammar, so the `/`
// after it is classified the same way it would be if the comment were
// absent. In each case below, `/foo/` starts a regex literal, not a
// division.
const a = /* trailing comment */ /foo/;
const b = // line comment before regex
  /bar/gi;
const c = /* one */ /* two */ /baz/.test('baz');
