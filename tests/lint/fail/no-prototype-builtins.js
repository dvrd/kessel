// no-prototype-builtins (L2024): calling Object.prototype methods directly.
function has(obj, key) {
  if (obj.hasOwnProperty(key)) {
    return true;
  }
  return obj.propertyIsEnumerable(key);
}
