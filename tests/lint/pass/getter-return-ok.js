// getter-return: valid getters that return
const obj = {
  get foo() {
    return 42;
  }
};

class Bar {
  get baz() {
    return this.x;
  }
}
