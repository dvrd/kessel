// ECMA-262 §16.2.2 — "It is a Syntax Error if any element of the
// ExportedBindings of ModuleItemList does not also occur in either the
// VarDeclaredNames of ModuleItemList or the LexicallyDeclaredNames of
// ModuleItemList." `export { foo };` with no `from` clause requires
// `foo` to be declared somewhere in the module.
export { foo };
