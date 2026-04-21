class Foo {
  #method() { return 42; }
  get() { return this.#method(); }
}
