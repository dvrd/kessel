// ES2019 — LINE SEPARATOR (U+2028) and PARAGRAPH SEPARATOR (U+2029)
// are now allowed as LITERAL characters inside string literals. Prior
// to ES2019 they were SyntaxErrors.
const ls = "a u+2028";
const ps = "b u+2029";
