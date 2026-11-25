// Template literal types in every position where the closing backtick is the
// last byte of an enclosing node. The spans are pinned by the golden
// tests/fixtures/spec/typescript/021_template_literal_type_spans.js.
type A = `a${string}b`   ;
type B = `a${string}b`   // comment
type C = `a${string}`  /* comment */ | 1
type W = `x`  ;
type U = `x` /* comment */ | `y`  
type X = `x`  [] ;
type E = `` ;
let v = x as `a${string}`  ;
let w = x satisfies `a${string}`  /* comment */ ;
type G = keyof `a${string}`  ;
type I = (a: `a${string}`  ) => `b${string}`  ;
interface K { a: `a${string}`  ; b(): `b${string}`  }
type L = { a: `z`   , b: `w${1}`  }
type M = `a${string}`  &  `b${number}`
class N { p: `a${string}`  = 'a'; q!: `b${string}`
}
type R<T extends `a${string}`  = `a${string}`  > = T
declare const s: `a${string}`  
type N3 = `a${B<C<D<E>>>}b${F<G>}c`   // comment
type P = `a${string}`  
