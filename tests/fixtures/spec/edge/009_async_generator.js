async function* asyncGen() {
  yield await Promise.resolve(1);
  yield 2;
}
