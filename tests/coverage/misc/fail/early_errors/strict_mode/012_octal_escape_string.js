// ECMA-262 §12.9.4 — LegacyOctalEscapeSequence (`\012`) and the
// NonOctalDecimalEscapeSequence escapes `\8` / `\9` are SyntaxErrors
// inside StringLiteral and TemplateLiteral when the surrounding code
// is strict. Allowed in sloppy script.
'use strict';
var legacy = "\012";
var eight  = "\8";
var nine   = "\9";
