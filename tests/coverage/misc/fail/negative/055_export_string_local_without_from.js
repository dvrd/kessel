// ECMA-262 §16.2.2 — ES2022 allows string-literal ModuleExportNames
// only as part of a re-export (`export { "foo" } from "m";`). A
// string literal in the local position of a named export without a
// `from` clause is a SyntaxError because the local name must refer to
// a BindingIdentifier in the current module.
export { "foo" };
