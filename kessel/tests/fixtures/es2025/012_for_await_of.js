// for-await-of in async context
async function process(stream) {
  for await (const chunk of stream) {
    console.log(chunk);
  }
}
