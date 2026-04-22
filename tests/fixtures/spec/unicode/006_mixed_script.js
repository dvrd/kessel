// Multiple scripts mixed inside one identifier. ECMA-262 doesn't
// prohibit this; a parser must accept any IdentifierStart+IdentifierPart*
// regardless of script boundary.
const a漢字 = 1;
const 日本x = 2;
const mixedπx = 3;
