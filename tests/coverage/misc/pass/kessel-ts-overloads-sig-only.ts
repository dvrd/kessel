// Conservative pre-pass on the FunctionDeclaration overload-chain
// check: when NO impl exists in the scope, the check is skipped.
// Matches oxc-semantic, which accepts sig-only ambient files like
// the babel typescript/function/overloads fixture.
export function f(x: number): number;
export function f(x: string): string;
