// Classic ASI insertion cases: no semicolon at end of line where next
// line begins with a token that cannot continue the current statement.
const a = 1
const b = 2
let c = a + b

function f() {
  return a
}
