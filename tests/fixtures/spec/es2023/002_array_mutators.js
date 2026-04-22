// ES2023 immutable / change-by-copy Array prototype methods. No syntax
// change \u2014 these are plain method calls \u2014 but a regression in call-
// expression parsing here surfaces quickly because the patterns are
// everywhere in modern code.
const arr = [3, 1, 2];
const sorted = arr.toSorted();
const reversed = arr.toReversed();
const spliced = arr.toSpliced(0, 1);
const withed = arr.with(0, 99);
const last = arr.findLast((x) => x > 0);
const lastIdx = arr.findLastIndex((x) => x > 0);
