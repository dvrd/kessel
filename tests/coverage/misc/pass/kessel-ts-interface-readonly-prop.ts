// Parser-shape lock-in: contextual `readonly` modifier on property /
// method signatures is absorbed into the following member rather than
// emitted as a separate bare `readonly` property signature.
//
// Pre-session-5 the parser produced
//   TSPropertySignature(readonly, no annotation)
//   TSPropertySignature(_A: T)
// for `readonly _A: T;`. Post-fix the parser produces a single
// TSPropertySignature(_A, readonly=true, type_annotation=T).
interface I {
  readonly _A: number;
  readonly _B: string;
  readonly [k: number]: string;
}

// Disambiguation: `readonly` IS the member name when followed by
// `:`, `?`, `(`, or `;` (or a newline). Each of these interfaces
// uses `readonly` exactly once so it doesn't trigger TS2300.
interface ReadonlyAsProp { readonly: number; }
interface ReadonlyAsOptional { readonly?: string; }
interface ReadonlyAsMethod { readonly(): void; }
interface ReadonlyAsBare { readonly; }
