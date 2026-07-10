// Passing counterparts for no-delete-var (L2021) and no-dupe-args (L2022):
// deleting an object property is fine, and distinct parameter names are fine.
function scrub(obj, a, b) {
  delete obj.temp;
  delete obj["key"];
  return a + b;
}
const sum = (x, y, z) => x + y + z;
