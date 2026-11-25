const forward = /\1(a)/;
const nested = /(\1a)/;
const disjunctive = /(a)|\1/;
const backward = /(?<=(a)\1)/;
const negative = /(?!(a))\1/;
const named = /\k<x>(?<x>a)/u;
const constructor = new RegExp("\\1(a)");
const call = RegExp(`\\k<x>(?<x>a)`, "u");
