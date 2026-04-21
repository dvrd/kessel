// Regression for commit 658f25f: "use strict" (and any other Directive
// Prologue) must appear in BOTH `program.directives` and `program.body` as
// an ExpressionStatement wrapping a StringLiteral, per ESTree §Directive
// Prologues. Prior to the fix, Kessel emitted the directive only in
// `directives` — downstream tools that walk `body` (most of them) saw a
// body that was missing the leading string statement, which drifted from
// OXC and broke any round-trip that reconstructed the source.
//
// Methodology: the regression verifier asserts the signature counts —
// at minimum 1 ExpressionStatement AND 1 StringLiteral (ESTree Literal)
// reachable from the body path, even though the first `body` entry here
// is the string literal itself (not followed by other statements).
"use strict";
const x = 1;
function f() {
  "use strict";
  return x;
}
