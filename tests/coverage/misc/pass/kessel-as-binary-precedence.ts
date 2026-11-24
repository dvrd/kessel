// `as` and `satisfies` have relational precedence and associate to the left:
// each line below asserts the type of the whole binary expression before it.
declare const x: number, a: number, b: number, c: number;
var sum = 1 + x as number;
var product = a * b as number;
var power = a ** b as number;
var compared = a < b as boolean;
var chained = a + b as number + c;
var checked = a + b satisfies number;
var nullish = a ?? b as number;
var text = `${1 + 2 as number}`;
