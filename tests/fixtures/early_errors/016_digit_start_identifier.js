// Digits are IdentifierPart but NOT IdentifierStart. `1a` is tokenised
// as a numeric literal `1` followed by identifier `a` — which is a
// SyntaxError because `1 a` is not a valid expression.
const 1a = 1;
