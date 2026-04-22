class Base {
  constructor(x) { this.x = x; }
}
class Child extends Base {
  constructor(x, y) {
    super(x);
    this.y = y;
  }
  method() {
    return super.x;
  }
}
