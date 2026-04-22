// ECMA-262 §14.10.1 — ReturnStatement is only allowed inside a
// FunctionBody. Top-level `return` in a script source is a SyntaxError.
// (Some hosts relax this; spec-correct behavior is to reject.)
return 42;
