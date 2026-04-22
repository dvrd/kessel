// ECMA-262 §12.9.4 — \u{H...H} code-point escape. Decodes to the
// indicated Unicode code point. Valid range: 0x0 .. 0x10FFFF inclusive.
const low = "\u{0}";          // U+0000 NUL
const one = "\u{41}";         // U+0041 'A'
const two = "\u{1F600}";      // supplementary plane (emoji)
const max = "\u{10FFFF}";     // upper bound (must parse)
