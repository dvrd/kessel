class Secret {
  #value;
  constructor(v) {
    this.#value = v;
  }
  get() {
    return this.#value;
  }
}
