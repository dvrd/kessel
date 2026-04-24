// ECMA-262 §12.9.3 — a LegacyOctalIntegerLiteral cannot be a BigInt
// literal. `0123n` is neither a valid DecimalBigInt (starts with `0`
// + digits, so lexer routes it through the legacy-octal arm) nor a
// valid OctalBigInt (which requires the modern `0o` prefix: `0o123n`).
// Always a SyntaxError, not strict-gated.
var n = 0123n;
