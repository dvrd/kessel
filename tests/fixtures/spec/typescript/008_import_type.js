// TS `import type` — type-only import, does not emit a runtime require.
// ESTree/TS: ImportDeclaration.importKind === "type".
import type { Foo } from "./foo";
import type Default from "./default";
import type * as NS from "./ns";
