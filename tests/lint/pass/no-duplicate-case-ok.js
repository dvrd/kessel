// no-duplicate-case (L2014) passing: distinct labels, including similar-looking
// but textually different expressions, are all fine.
function classify(x) {
  switch (x) {
    case 1:
      return "one";
    case 2:
      return "two";
    case x + 1:
      return "next";
    case x + 2:
      return "after";
    default:
      return "other";
  }
}
