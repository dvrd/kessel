function choose(flag) {
  if (flag) {
    return 1;
  } else {
    throw new Error("no value");
  }
  consume();
}
