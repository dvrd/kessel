// TS generic type parameter on a function declaration + call. Kessel
// AST: FunctionDeclaration.typeParameters = TSTypeParameterDeclaration.
function identity<T>(x: T): T {
  return x;
}
const a = identity<number>(42);
const b = identity<string>("hi");
