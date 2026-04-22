// TS conditional type: `T extends U ? X : Y`.
// ESTree/TS nodes: TSConditionalType { checkType, extendsType, trueType, falseType }.
type IsString<T> = T extends string ? true : false;
type Unbox<T> = T extends { value: infer V } ? V : T;
