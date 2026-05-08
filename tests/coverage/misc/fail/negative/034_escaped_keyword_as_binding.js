// ECMA-262 §12.7.2 — `\u0076ar` cooks to "var". Using it as a
// BindingIdentifier (the declared name of a `var` declarator) fails
// the `Identifier : IdentifierName but not ReservedWord` rule the
// same way it fails at IdentifierReference position.
//
// Note: the outer `var` is a real keyword token (not escaped); only
// the declared name has the escape. The outer `var` parses normally
// and then the binding position rejects the escaped "var".
var \u0076ar = 1;
