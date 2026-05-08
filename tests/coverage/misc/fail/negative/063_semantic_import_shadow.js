// ECMA-262 §16.2.1 / §14.3.1.1 — an ImportDeclaration binds a name at
// module-body lexical scope; a subsequent `let` / `const` / `class` /
// `function` with the same name is a SyntaxError. OPT-6 catches via
// the module-top-level scope walk.
//
// verifier-flags: --show-semantic-errors
import x from "m";
let x;
