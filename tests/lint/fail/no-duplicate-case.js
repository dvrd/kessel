// no-duplicate-case (L2014): two identical case labels are dead code.
function classify(x) {
  switch (x) {
    case 1:
      return "one";
    case 2:
      return "two";
    case 1:
      return "uno";
  }
}
