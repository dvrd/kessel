// getter-return: getter must return a value
const obj = {
  get foo() {
    console.log("no return");
  }
};

class Bar {
  get baz() {
    this.x = 1;
  }
}
