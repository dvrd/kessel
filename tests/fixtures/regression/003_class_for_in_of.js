// Regression (two bugs, same class):
//   1. parse_for() used `transmute(^VariableDeclaration)decl_stmt` which
//      corrupted left_decl by reading the Statement union header as a
//      VariableDeclaration struct.
//   2. ForIn/ForOf emit used `print_statement_ast((^Statement)(decl))` which
//      re-cast back through a fake ^Statement with mismatched tag.
// Either bug would corrupt `for (let k in obj)` inside a class method.
// Fixed: type assertion at parse time, inline emit via body helper.
class Regression003 {
  iterate(obj, arr) {
    const keys = [];
    for (let k in obj) {
      keys.push(k);
    }
    for (const v of arr) {
      keys.push(v);
    }
    // No-declaration variants to exercise the `left_expr` branch.
    let x;
    for (x in obj) {
      keys.push(x);
    }
    let y;
    for (y of arr) {
      keys.push(y);
    }
    return keys;
  }
}
