// ES2018 — named capture groups + backreferences.
const m = /(?<year>\d{4})-(?<month>\d{2})/;
const b = /(?<first>\w)-\k<first>/;
const la = /(?=foo)/;
const ln = /(?<=foo)/;
const neg = /(?<!foo)/;
