// Regression: ForStatement emit used `print_statement_ast((^Statement)(decl))`
// which cast ^VariableDeclaration to ^Statement at the pointer level. The
// VariableDeclaration struct's bytes were then dispatched via the Statement
// union tag discriminant, reading garbage. Nested inside a class method body
// this SIGSEGV'd deep under ClassBody emit (real-world: tone.js, mathjax.js,
// marked.js, etc.).
// Fixed: emit VariableDeclaration inline via print_variable_declaration_body.
class Regression002 {
  run() {
    const arr = [];
    for (let i = 0; i < 10; i += 1) {
      arr.push(i * 2);
    }
    for (var j = 0, k = 5; j < k; j++) {
      arr[j] = j;
    }
    for (const init = Date.now(); false; ) {
      break;
    }
    return arr;
  }
  nested() {
    const fn = () => {
      for (let n = 0; n < 3; n += 1) {
        this.run();
      }
    };
    fn();
  }
}
