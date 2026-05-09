// TS2300 — declaration-merge dup detection inside a TS namespace
// body (FunctionDeclaration7-style scope). Two `class C` decls in
// the same namespace scope cannot merge, just like at Program top
// level.
namespace M {
  class C {}
  class C {}
}
