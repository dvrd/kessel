// ECMA-262 §13.2 — `yield` is reserved as a BindingIdentifier anywhere
// inside a GeneratorDeclaration / GeneratorExpression, regardless of
// strict / sloppy mode. Plain function sloppy still allows `var yield`.
function* g() {
	var yield = 1;
}
