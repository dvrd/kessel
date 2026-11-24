// Template literals nested 64 deep.
// The lexer once tracked template interpolations in `[8]u8`: nesting depth 9
// and 256 open braces were mis-lexed and this valid program was rejected.
// Generated shape; see tests/verifiers/verify_template_nesting.js.
var x = `a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${0}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`;
