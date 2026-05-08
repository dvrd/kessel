// ECMA-262 §14.7.5 — `for await (LeftHandSide of Expression) Body` is
// only valid inside an AsyncFunctionBody, AsyncGeneratorBody, or at
// Module top-level (top-level async). Using it inside a plain
// (non-async) function is a SyntaxError. This fixture uses the
// non-async-function form; the top-level-in-script form is covered
// separately under early_errors/module_context/.
function f() {
	for await (const x of y) {
		use(x);
	}
}
