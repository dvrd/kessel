// Comma operator / call argument list: `,` puts us back in expression
// context, so `/` is a RegExp.
const pair = [1, /abc/g];
fn(1, /xyz/i);
