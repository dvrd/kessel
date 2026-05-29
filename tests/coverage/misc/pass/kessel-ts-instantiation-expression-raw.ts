// TSInstantiationExpression (`foo<T>`) in expression position. Exercises the
// raw_transfer binary walker's TSInstantiationExpression case, which previously
// fell through the (now removed) default and left the inner expression and
// type-argument pointers un-rewritten in the binary buffer.
const a = makeBox<number>;
const b = makeBox<number, string>;
const c = (obj.factory)<Foo>;
const d = makeBox<number><string>;
