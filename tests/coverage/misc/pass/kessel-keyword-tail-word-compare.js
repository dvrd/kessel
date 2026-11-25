// Long keywords and similarly spelled identifiers that differ in a tail byte.
// A final near-keyword also checks lookup without trailing source padding.
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
