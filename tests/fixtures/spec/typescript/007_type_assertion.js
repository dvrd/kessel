// TS `<Type>expr` assertion syntax (not available in TSX — clashes
// with JSX). ESTree/TS: TSTypeAssertion.expression + .typeAnnotation.
const a = <string>value;
const b = <number>(x + y);
