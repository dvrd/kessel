// Template literal with a broken substitution — the closing `${` must
// not swallow the outer statement terminator.
const broken = `hello ${1 + } world`;
const anchor_after_error = 1;
