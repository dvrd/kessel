// ECMA-262 §12.9.4 / §12.9.6 — LegacyOctalEscapeSequence and
// NonOctalDecimalEscapeSequence (\\8 / \\9) inside an untagged
// TemplateLiteral are SyntaxErrors in strict mode, just like plain
// StringLiterals. Tagged template literals (`tag\`...\``) get a
// cooked/raw pair where invalid escapes render `cooked: null` instead
// of failing; that case is out of scope for this fixture.
'use strict';
var legacy = `\012`;
var eight  = `\8`;
var nine   = `\9`;
