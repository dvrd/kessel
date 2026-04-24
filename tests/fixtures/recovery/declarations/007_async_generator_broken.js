// Async generator method header with a malformed parameter default.
const obj = {
  async *gen(x = ) {
    yield x;
  }
};
const anchor_after_error = 1;
