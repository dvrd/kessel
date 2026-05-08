// ECMA-262 §14.3.1.1 — "It is a Syntax Error if the LexicallyDeclaredNames
// of ... contains any duplicate entries." Covered by OPT-6's scope pass
// (--show-semantic-errors). Cross-statement duplicates are the common case
// that the per-declaration dup check in Session 6 doesn't see.
//
// verifier-flags: --show-semantic-errors
let x = 1;
let x = 2;
