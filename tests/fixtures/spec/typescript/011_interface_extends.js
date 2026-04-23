// TS-D: `interface extends` — single-parent, multi-parent, and qualified
// (namespace.Member) parent forms. Each heritage entry parses as an
// `TSInterfaceHeritage` / `TSExpressionWithTypeArguments` node (OXC
// emits the latter) with a typeName/expression + optional type
// arguments. Kessel's shape must match OXC's deep structure, verified
// by the spec-fixtures runner.
interface Base {
  id: number;
}

interface WithKind {
  kind: string;
}

interface Child extends Base {
  name: string;
}

interface Many extends Base, WithKind {
  extra: boolean;
}

interface Generic<T> extends Base {
  value: T;
}

interface QualifiedParent extends ns.Base {
  hook: () => void;
}
