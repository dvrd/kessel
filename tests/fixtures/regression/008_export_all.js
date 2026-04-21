// Regression for commit 75b7ada: ExportAllDeclaration must consume its
// trailing semicolon, otherwise Kessel emitted a spurious EmptyStatement
// between the `export * from "..."` and the next real statement. This
// shifted `body` indices for every downstream traversal.
//
// Methodology: the verifier asserts exactly the count of real statements
// here (3 ExportAll + 1 VariableDeclaration + 1 FunctionDeclaration = 5)
// and forbids any EmptyStatement in the top-level body.
export * from "./a";
export * from "./b";
export * as ns from "./c";

const sentinel = 42;
function f() {
  return sentinel;
}
