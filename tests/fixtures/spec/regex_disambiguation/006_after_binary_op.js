// After a binary operator, RHS is expression. `/` is RegExp.
// Also: prefix !, typeof, etc. open expression context.
const r = !/abc/.test(s);
const t = typeof /x/;
const u = void /y/;
