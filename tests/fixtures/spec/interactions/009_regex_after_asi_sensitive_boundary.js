// Interaction: ASI boundary followed by a line that starts with `/`. The
// first `const` declaration has no trailing semicolon, so ASI must close
// it; only then does the tokeniser see the following `/` at the start of
// a new statement, where it must be interpreted as a regex literal rather
// than as a division operator against the previous value.
//
// If ASI or the regex-vs-division disambiguation is wrong, this file
// fails to parse entirely.
const a = 'foo'
const b = /bar/.test(a)
void b
