// TSImportEqualsDeclaration — TS's `import X = ModuleReference` form.
// Distinct from regular `import X from "m"` and ImportDeclaration.
//
// Three legal moduleReference shapes per the TS grammar:
//   * Identifier              `import X = N`
//   * Qualified entity name   `import Y = A.B.C`
//   * External module ref     `import Z = require("./mod")`
//   * Type-only variant       `import type T = Foo`
//
// Closes 275 of the 291 OXC corpus rejects in the "Expected from, got ="
// cluster (S26 W6 phase 3 bug class #4). Pre-fix kessel ate `import X` as
// a default-import binding and choked on `=` looking for `from`.
import X = N;
import Y = A.B.C;
import Z = require("./mod");
import type T = Foo;
