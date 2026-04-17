// Generators complejos
function* fibonacci() {
  let a = 0, b = 1;
  while (true) {
    yield a;
    [a, b] = [b, a + b];
  }
}

function* range(start, end, step = 1) {
  for (let i = start; i < end; i += step) {
    yield i;
  }
}

function* combined() {
  yield* [1, 2, 3];
  yield* range(4, 7);
  yield* arguments;
}

const gen = {
  *generator() {
    yield this.value;
  }
};
