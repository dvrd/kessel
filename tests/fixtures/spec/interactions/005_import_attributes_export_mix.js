// Interaction: import attributes (`with { type: 'json' }`) applied across
// every import/export form that carries a module specifier.
//
// - default import       with attributes
// - namespace import     with attributes
// - named re-export from with attributes
// - namespace re-export  with attributes
//
// This is a module goal file (import/export at top level). The parser must
// treat the `with { ... }` clause as an attributes list — not as a
// with-statement or a generic block — at every specifier position.
import data from './x.json' with { type: 'json' };
import * as ns from './n.json' with { type: 'json' };
export { y } from './y.js' with { type: 'json' };
export * as reexp from './z.json' with { type: 'json' };
