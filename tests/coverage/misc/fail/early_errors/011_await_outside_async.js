// ECMA-262 §15.8.1 — `await` is reserved inside an async function /
// module; outside both it's an identifier in script mode. Here we use
// it in a non-async function body as an operator — SyntaxError.
function f() { return await 1; }
