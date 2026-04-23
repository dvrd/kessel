// Lexical: template literals carry two strings per quasi — a `raw` form
// (exactly the bytes the programmer typed between the backticks) and a
// `cooked` form (with escape sequences decoded). Tagged templates expose
// both via `strings.raw[i]` and `strings[i]`. Each case below has a
// distinct raw/cooked pair so the parser can't fuse them.
const plain        = `\u0041\n\t`;        // cooked: "A\n\t"; raw: "\\u0041\\n\\t"
const multiline    = `line1\nline2`;       // cooked: "line1\nline2"
const tag_cooked   = tag`\u0041${1}\t`;    // cooked quasi seg 0: "A"
const tag_raw      = String.raw`\u0041${1}\t`;
const with_newline = `hard
break`;
