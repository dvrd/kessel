// ECMA-262 §12.9.4 — LineContinuation inside a StringLiteral: backslash
// immediately followed by LineTerminatorSequence. Evaluates to empty
// string (NOT a literal newline), joining the two halves of the literal.
const joined = "abc\
def";
// Kessel must produce StringLiteral.value === "abcdef".
const withCR = 'one\
two';
