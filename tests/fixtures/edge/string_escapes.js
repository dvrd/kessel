// Comprehensive string-escape fixture for Bug E verification.
// Each declaration's string must match OXC's escape-decoded value.
var simpleEscapes  = "quote:\"tab:\tnewline:\ncr:\rbs:\bff:\fvt:\vnull:\0bell:\\";
var singleQuoted   = 'quote:\'tab:\tbackslash:\\';
var hexEscapes     = "\x20\x41\x61\x00\xff\x7f";
var u4Escapes      = "\u0041\u0061\u00e9\u2603\u0000\uffff";
var uBraceAscii    = "\u{41}\u{61}\u{7F}";
var uBraceAstral   = "\u{1F600}\u{1F4A9}\u{10FFFF}";
var mixedEscapes   = "pre\x20mid\u0041post\tend";
var slashAndQuote  = "\/path\\to\"thing";
var emptyString    = "";
var onlyEscapes    = "\n\t\r";
var adjacentEscape = "a\x41b\u0042c";
var bsFollowedBy   = "\a\z\Q\%";   // \c → c fallback for non-escape chars
var charclassLike  = "[\x20\t]";
var longRun        = "abcdefghijklmnopqrstuvwxyz 0123456789 \x20\x09\x0a";
// Line continuation — the `\` followed by LF must produce nothing.
var lineCont = "one\
two";
