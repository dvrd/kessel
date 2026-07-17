// no-this-before-super: this used before super() in derived constructor
class Child extends Parent {
  constructor() {
    this.x = 1;
    super();
  }
}
