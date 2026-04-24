// Deep nesting with a break three levels down. Each outer paren must
// close cleanly even though the innermost expression is incomplete.
const broken = ((a + (b * (c - ))) || d);
const anchor_after_error = 1;
