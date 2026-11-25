// Regression: template tokens start after the opening backtick and end before
// the closing one, and two places in the type parser used those offsets as
// node boundaries.
//
//   * A substitution-free template type (`W` below) started one byte late, on
//     the first character instead of the backtick, and so did a union or array
//     type that begins with it.
//   * After a template type with substitutions, the "end of the last token"
//     stayed in front of the closing backtick. Every node that closes on it
//     ended one byte short: a type alias without a semicolon, `as` and
//     `satisfies` expressions, `keyof`, function types, intersections, method
//     and property signatures, class properties and type parameter defaults.
//
// Trivia follows most types on purpose: no span may reach into it. Every span
// in this file matches oxc-parser 0.127.0.
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
