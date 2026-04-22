class Branded {
  #brand;
  constructor() {
    this.#brand = true;
  }
  static isBranded(obj) {
    return #brand in obj;
  }
}
