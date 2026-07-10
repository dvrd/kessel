// no-unsafe-negation (L2010) + no-compare-neg-zero (L2011).
if (!key in object) {
  use(key);
}
if (value === -0) {
  handle(value);
}
