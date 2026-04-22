// TS union / intersection types. ESTree/TS:
// TSUnionType.types[], TSIntersectionType.types[].
type StringOrNumber = string | number;
type Both = HasA & HasB;
type Complex = (A | B) & C;
type Literal = "a" | "b" | "c";
