// Parser-shape lock-in: generic interface methods (`m<U>(): T;`)
// are parsed as a single TSMethodSignature with type_parameters set.
// Pre-session-5 the parser misparsed each as a bare TSPropertySignature
// followed by a separate TSCallSignatureDeclaration (split shape).
// Multiple generic methods of the same name form a legal overload set,
// which the dup checker accepts via its method-overload carve-out.
interface I {
  m<U>(): U;
  m<T extends string>(arg: T): T;
  n?<T>(x: T): T;
}
