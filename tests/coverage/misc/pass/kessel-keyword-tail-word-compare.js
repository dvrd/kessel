// Regression: keyword-tail word-compare (lexer.odin lookup_keyword_by_letter).
// The length>4 branch verifies a keyword's bytes 4.. via a single masked u64
// compare against KEYWORD_TAIL. This fixture exercises both halves of that
// path: (1) real long keywords must still classify as keywords, and (2)
// identifiers that share first-char + length with a long keyword but differ in
// a tail byte must stay identifiers. The trailing near-keyword identifier sits
// within 12 bytes of EOF so it takes the bounded byte-pack fallback (the
// unaligned 8-byte fast load is skipped because there is no trailing padding).
function returnz(whilex, typeofy) {
  var instanceoff = whilex + typeofy;   // 11 chars: longer than any keyword.
  let continuez = instanceoff;          // 9 chars vs `continue` (8) — length differs.
  const debuggee = continuez;           // 8 chars vs `debugger` — tail differs.
  while (returnz) {
    if (instanceoff) { continue; }
    break;
  }
  return debuggee;
}

typeof returnz;
var probe = 1 instanceof Object;
var functiom = function () { return 0; }; // 8 chars vs `function`: byte 7 differs.
var keyofx = functiom;
var overridd = keyofx;                    // 8 chars vs `override`: byte 7 differs.
functiom
