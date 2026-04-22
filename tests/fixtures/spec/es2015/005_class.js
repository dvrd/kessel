class Animal {
  constructor(name) {
    this.name = name;
  }
  speak() {
    return this.name;
  }
  get title() {
    return this.name;
  }
  set title(v) {
    this.name = v;
  }
  static create(n) {
    return new Animal(n);
  }
}
