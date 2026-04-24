// ECMA-262 §14.3.1.1 / §16.1.3 — a VariableStatement's BoundNames
// cannot appear in the LexicallyDeclaredNames of the same body scope.
// `let x; var x;` is a SyntaxError because both declarations share the
// outer (Program / FunctionBody) scope. OPT-6's scope pass catches the
// clash.
//
// verifier-flags: --show-semantic-errors
let x;
var x;
