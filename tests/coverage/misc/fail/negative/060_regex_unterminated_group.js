// Group opened with `(` but never closed before the terminating `/`.
// The lexer reports "Unterminated group" anchored at the pattern start.
const r = /abc(def/;
