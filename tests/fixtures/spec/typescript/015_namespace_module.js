// TS-D: `namespace` / `declare module` declarations — exercises the
// TSModuleDeclaration shape across its three forms:
//   1. plain `namespace` with a TSModuleBlock body (statements inside)
//   2. `declare module 'name'` ambient module (string id, declare=true)
//   3. dotted name `namespace A.B.C { ... }` which desugars to a chain
//      of nested TSModuleDeclaration nodes (body is a recursive
//      ^TSModuleDeclaration, not a ^TSModuleBlock)
//
// Each form must produce a TSModuleDeclaration node whose `id`,
// `body`, `declare`, `global`, and `kind` slots match OXC's deep
// shape. The spec-fixtures runner pins the JSON output below; the
// new W3 binary-buffer gate (verify_ts_statements_jsx.js) walks the
// raw-transfer buffer and asserts that the same id/body slots resolve
// to in-buffer offsets, where before W3 they held bare arena
// addresses outside the buffer.
namespace Geo {
  export const PI = 3.14;
  export function area(r: number): number {
    return PI * r * r;
  }
}

declare module "ext-pkg" {
  export function init(opts: { debug: boolean }): void;
  export const VERSION: string;
}

namespace Outer.Inner {
  export type ID = string;
  export const TAG = "inner";
}
