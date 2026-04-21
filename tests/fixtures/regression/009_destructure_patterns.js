// Regression for commit 72275c8: print_pattern_ast had two emit paths that
// produced invalid JSON on real code (antd.js, anything with destructuring):
//
// 1. ArrayPattern.elements emitted each pattern directly without wrapping
//    in `{...}`. Fix: wrap each element; holes (`[,,x]`) emit bare `null`.
// 2. ObjectPattern.value for ^AssignmentPattern / ^RestElement /
//    ^MemberExpression variants fell through to a bare `null` wrapped in
//    `{...}` — i.e. `"value": {null}` (invalid JSON). Fix: #partial switch
//    on the variant; wrap only when print_pattern_ast will actually emit
//    JSON fields.
//
// Methodology: exercise the exact surface the bug lived on — ArrayPattern
// with holes, ObjectPattern with AssignmentPattern values (`{ a = 1 }`),
// ObjectPattern with RestElement values (`{ ...rest }`), and nested mixes.
// The verifier both asserts the node types are present AND runs the output
// through JSON.parse, which fails hard on the invalid-JSON regression.

// ArrayPattern: dense + sparse (holes) + rest
const [a, b] = [1, 2];
const [, , c] = [1, 2, 3];
const [d, , e, ...rest] = [1, 2, 3, 4, 5];

// ObjectPattern with every value variant
const { p } = { p: 1 };                  // Identifier value
const { q = 10 } = {};                   // AssignmentPattern value (default)
const { r: rr = 20 } = {};               // AssignmentPattern with alias
const { s, ...tail } = { s: 1, x: 2 };   // RestElement value
const { u: [uu, vv] } = { u: [1, 2] };   // ArrayPattern as value
const { w: { ww } } = { w: { ww: 1 } };  // ObjectPattern as value

// Function params exercise the same printer from a different entry point.
function fn({ x = 1, y: yy, ...rest }, [first, , third]) {
  return x + yy + first + third + Object.keys(rest).length;
}
fn({ x: 1, y: 2, z: 3 }, [10, 20, 30]);
