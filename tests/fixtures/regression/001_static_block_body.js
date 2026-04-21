// Regression: parse_static_block used `transmute(^BlockStatement)block_stmt`
// which read the Statement union header as BlockStatement fields, zeroing
// `body`. Static blocks emitted as `"body": []` regardless of contents.
// Fixed: extract via type assertion on the union variant.
class Regression001 {
  static {
    this.a = 1;
    this.b = 2;
    console.log("initialised");
  }
  static x = 42;
  static {
    const tmp = this.a + this.b;
    if (tmp > 0) {
      this.ready = true;
    }
  }
}
