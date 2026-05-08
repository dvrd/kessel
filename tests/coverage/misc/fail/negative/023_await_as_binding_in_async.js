// ECMA-262 §13.2 — `await` is reserved as a BindingIdentifier inside
// any AsyncFunctionDeclaration / AsyncFunctionExpression / AsyncArrow
// / AsyncGenerator / Module. Plain sloppy script function still
// accepts `var await = 1;`.
async function f() {
	var await = 1;
	return await;
}
