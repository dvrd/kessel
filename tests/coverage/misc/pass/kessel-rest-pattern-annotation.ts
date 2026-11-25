// A destructured rest parameter keeps its type annotation, and an
// unparenthesized async arrow starts at `async`. Both parse either way; the
// declaration verifier checks the resulting types and spans.
function pair(...[a, b]: [number, number]): number { return a + b; }
function size(...{ length }: string[]): number { return length; }
const first = (...[head]: string[]): string => head;
const later = async value => value;
