// Template interpolation state must survive the parser's speculative parses
// (lexer_snapshot / lexer_restore) and the `>>` split in type arguments, at
// nesting depths on both sides of the old 8-level limit.
let a1 = `${ {} as Foo<Bar<Baz>> }`;
let a2 = `${ y as Foo<Bar<Baz>>}`;
type T3 = `a${Foo<Bar<Baz>>}b`;
type T4 = `a${`b${Foo<Bar<Baz>>}c`}d`;
let a5 = `p${ `${ y as Foo<Bar<Baz>>}` }q`;
let a6 = `p${ {a: `${ y as Foo<Bar<Baz>>}` } }q`;
type T7 = `a${{k: `b${Foo<Bar<Baz>>}c`}["k"]}d`;
let a8 = `${ f<A<B>>(1) }${ {a:1}.a }`;
let a9 = `a${`a${[((a = `${`${ {b: {c: 1}}.b.c }`}`, d) => a)(), (1, `${`${ {b: 1}.b }`}`), async (e = `${ {f: `${1}`}.f }`) => e]}b`}b`;
let a10 = `a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${[((a = `${`${ {b: {c: 1}}.b.c }`}`, d) => a)(), (1, `${`${ {b: 1}.b }`}`), async (e = `${ {f: `${1}`}.f }`) => e]}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`;
let a11 = `a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${`a${<T,>(g = `${`${ {h: 1}.h }`}`) => g}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`}b`;
