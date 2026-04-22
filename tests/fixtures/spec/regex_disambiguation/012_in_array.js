// `[` puts us in expression context; inside array literal each element
// is an AssignmentExpression, so `/.../` is RegExp.
const patterns = [/foo/, /bar/g, /baz/i];
