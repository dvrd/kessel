// TS-D: `const enum` — numeric, string, and computed initializers,
// plus the `const` modifier on the TSEnumDeclaration node. Each
// enum must emit `{ const: true, members: [...] }` with the same
// shape OXC produces, verified by the spec-fixtures runner.
const enum Direction {
  Up,
  Down,
  Left = 100,
  Right,
}

const enum Status {
  Active = "ACTIVE",
  Inactive = "INACTIVE",
}

const enum Mixed {
  Zero = 0,
  One = 1 << 0,
  Two = 1 << 1,
  Four = 1 << 2,
}

declare const enum AmbientFlags {
  None = 0,
  ReadOnly = 1,
}
