// Tricky case: `{} /x/g`. `{}` is a BlockStatement (statement context),
// so `/x/g` at the start of the next statement is a RegExp. Kessel must
// choose regex here \u2014 if it thought `{}` was an empty object expression,
// it'd interpret the `/` as division and produce `{} / x / g;`.
{}
/abc/g;
