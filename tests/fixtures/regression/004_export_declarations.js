// Regression: ExportNamedDeclaration / ExportDefaultDeclaration emit used
// `print_statement_ast((^Statement)(decl))` where `decl` was a ^Declaration.
// ^Declaration has 7 variants, ^Statement has 25; the tag ordinals differ
// (e.g. VariableDeclaration is Declaration tag 1 but Statement tag ~20),
// so dispatching with the wrong tag invoked a random case — typically
// BlockStatement — and dereferenced garbage fields. Crashes appeared only
// on export-heavy modules whose exported declarations flowed through the
// dispatch path with class subtrees in scope.
// Fixed: print_declaration_ast rebuilds a ^Statement whose tag is assigned
// from the inner variant, giving the correct tag ordinal for Statement.
export const REG_CONST = 1;
export let regLet = 2;
export var regVar = 3;
export function regFunction() {
  return REG_CONST + regLet + regVar;
}
export class RegClass {
  constructor() {
    this.value = regFunction();
  }
  get doubled() {
    return this.value * 2;
  }
}
export default class RegDefault extends RegClass {
  method() {
    return this.doubled;
  }
}
