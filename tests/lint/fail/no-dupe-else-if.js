// no-dupe-else-if (L2023): a repeated condition makes a branch unreachable.
// Includes a triple duplicate to prove the report is not emitted twice.
function classify(x) {
  if (x === 1) {
    return "a";
  } else if (x === 2) {
    return "b";
  } else if (x === 1) {
    return "dead";
  } else if (x === 1) {
    return "also dead";
  }
  return "z";
}
