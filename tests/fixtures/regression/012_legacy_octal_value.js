// Regression: a LegacyOctalIntegerLiteral (Annex B.1.1) was given its decimal
// reading, so `010` had the value 10 in the AST instead of 8. This golden pins
// the `value` of every zero-prefixed spelling against what the engine
// evaluates:
//
//   010 -> 8, 012 -> 10, 0777 -> 511, 00 -> 0, 07 -> 7, 0007 -> 7
//   08 -> 8, 09 -> 9, 089 -> 89     (NonOctalDecimalIntegerLiteral: decimal)
//   08.5 -> 8.5, 09e1 -> 90         (decimal, so a fraction and exponent apply)
//   0o10 -> 8, 0O10 -> 8            (modern octal, unchanged)
//
// The last three need more than 64 bits and check the rounding to f64:
// 2^63 - 1 rounds up to 2^63, 2^66 + 1 rounds down to 2^66, and
// 2^66 + 2^13 + 1 lies just above a tie and rounds up to 2^66 + 2^14.
010;
012;
0777;
00;
07;
0007;
08;
09;
089;
08.5;
09e1;
0o10;
0O10;
0777777777777777777777;
010000000000000000000001;
010000000000000000020001;
