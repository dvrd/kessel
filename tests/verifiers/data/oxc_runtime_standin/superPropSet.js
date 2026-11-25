// Stand-in for the helper of the same name in @oxc-project/runtime, which the
// pinned bench packages do not include. Written after the Babel helper; an
// ES module, so it is strict code as the published ESM helper is.
function _superPropSet(t, e, o, r, p, f) {
  if (!Reflect.set(Object.getPrototypeOf(f ? t.prototype : t), e, o, r) && p) throw new TypeError("failed to set property");
  return o;
}
export default _superPropSet;
// require() of this module returns the function itself, as the CommonJS helper does.
export { _superPropSet as "module.exports" };
