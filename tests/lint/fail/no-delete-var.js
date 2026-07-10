// no-delete-var (L2021): deleting a bare variable is invalid.
function scrub(obj) {
  var x = 1;
  delete x;
  return obj;
}
