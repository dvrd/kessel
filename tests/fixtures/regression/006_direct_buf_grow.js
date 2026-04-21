// Regression: the JSON direct_buf was sized at `len(source) * 20` bytes,
// based on "compact ≈ 9×, pretty ≈ 20×" before ClassBody emit was full.
// With full emit the pretty-mode expansion for class-heavy code exceeds
// 20× source, causing an out-of-bounds write around src/main.odin:62.
// Fixed: direct_reserve() grows direct_buf by doubling before every
// direct-mode write so the estimate is only a starting point.
//
// This fixture keeps the source small but forces a large JSON by packing
// many short class members; each member costs ~200-400 bytes in pretty
// JSON (MethodDefinition + FunctionExpression + body + indent), so 20
// members easily push past 20× source.
class Regression006 {
  a0(){}a1(){}a2(){}a3(){}a4(){}a5(){}a6(){}a7(){}a8(){}a9(){}
  b0(){}b1(){}b2(){}b3(){}b4(){}b5(){}b6(){}b7(){}b8(){}b9(){}
  c0(){}c1(){}c2(){}c3(){}c4(){}c5(){}c6(){}c7(){}c8(){}c9(){}
  d0(){}d1(){}d2(){}d3(){}d4(){}d5(){}d6(){}d7(){}d8(){}d9(){}
}
