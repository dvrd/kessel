// ECMA-262 §15.7.1 — ClassDeclaration / ClassExpression have a
// BindingIdentifier that's *always* strict (class bodies are
// implicitly strict, and the class name is in the enclosing TDZ).
// So `class let`, `class implements`, `class yield`, `class static`
// are all SyntaxErrors regardless of the surrounding strict / sloppy
// setting. This is the always-strict variant; plain `var let = ...`
// in sloppy script stays legal.
class let {}
class implements {}
