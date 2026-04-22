async function consume(stream) {
  for await (const chunk of stream) {
    process(chunk);
  }
}
async function* generate() {
  yield 1;
  yield 2;
  yield 3;
}
