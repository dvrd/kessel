class Logger {
  #format(msg) {
    return `[LOG] ${msg}`;
  }
  log(msg) {
    console.log(this.#format(msg));
  }
}
