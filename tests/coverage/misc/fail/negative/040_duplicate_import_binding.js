// ECMA-262 §16.2.2 — BoundNames of an ImportClause must not contain
// duplicate entries. All specifier kinds (ImportSpecifier,
// ImportDefaultSpecifier, ImportNamespaceSpecifier) contribute their
// LOCAL name (the identifier after `as`, or the identifier itself).
// Here `a` is the imported-name for the first specifier AND the
// local-name for the second (aliased via `as a`), so both add `a` to
// BoundNames — that duplicate triggers the early error. Covers the
// mixed default+named form too (`import a, {a} from "m";` — same
// rejection).
import {b as a, c as a} from "m";
