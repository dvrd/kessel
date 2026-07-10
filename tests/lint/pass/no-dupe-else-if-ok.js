// no-dupe-else-if (L2023) passing: every condition in the chain is distinct.
function classify(x) {
  if (x === 1) {
    return "a";
  } else if (x === 2) {
    return "b";
  } else if (x === 3) {
    return "c";
  } else {
    return "z";
  }
}
