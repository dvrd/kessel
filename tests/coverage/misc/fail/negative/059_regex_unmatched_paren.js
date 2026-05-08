// Unbalanced closing `)` in a regex pattern — the lexer tracks group
// depth so an unmatched `)` is flagged at the offending offset rather
// than rolling into the rest of the pattern as a literal.
const r = /abc)def/;
