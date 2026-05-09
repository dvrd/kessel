// Lock-in: interface method-signature overloads on the same name are
// LEGAL. The interface dup check carves out pure method overload sets
// (multiple TSMethodSignature with kind=.Method on the same name).
interface I {
  m(x: number): number;
  m(x: string): string;
  m(x: any): any;
}
