// Lexical: numeric separators (`_`) across every numeric base and suffix
// the spec allows. Each literal must tokenise as one NumericLiteral with
// the separators stripped from the cooked value — a `1_000` is the number
// 1000, not `1` followed by something else.
const decimal   = 1_000_000;
const hex       = 0xff_ff_ff;
const binary    = 0b1010_1010;
const octal     = 0o77_77;
const bigint    = 1_000n;
const float     = 1_0.5_5;
const exponent  = 1_0.5_5e1_0;
const neg_exp   = 1e-1_0;
