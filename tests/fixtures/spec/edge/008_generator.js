function* gen() {
  yield 1;
  yield 2;
  yield* [3, 4];
  return 5;
}
const g = gen();
g.next();
