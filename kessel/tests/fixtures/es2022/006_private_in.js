class A {
  #x = 1;
  static has(obj) {
    return #x in obj;
  }
  eq(other) {
    if (#x in other) return true;
    return false;
  }
}
