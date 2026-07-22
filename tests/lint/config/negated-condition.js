// no-negated-condition (L4098, default-off): negated test with an else branch.
// Enabled explicitly via --rule so this fixture must report a diagnostic.
function f(a) {
  if (!a) {
    return 1;
  } else {
    return 2;
  }
}
