// Annex B.1.1: a LegacyOctalIntegerLiteral is read in base eight, so `010` is
// eight. Kessel used to store ten because the digits were accumulated in base
// ten. `08` and `09` are NonOctalDecimalIntegerLiterals and stay decimal.
// Sloppy script only: strict code rejects every one of these spellings.
var eight = 010;
var ten = 012;
var decimal = 08 + 09 + 089;
var modern = 0o10 + 0O10;
var wide = 0777777777777777777777;
