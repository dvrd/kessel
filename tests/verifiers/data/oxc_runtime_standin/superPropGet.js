// Stand-in for the helper of the same name in @oxc-project/runtime, which the
// pinned bench packages do not include. Written after the Babel helper; an
// ES module, so it is strict code as the published ESM helper is.
function _superPropGet(t, o, e, r) {
  var p = Reflect.get(Object.getPrototypeOf(1 & r ? t.prototype : t), o, e);
  return 2 & r && "function" == typeof p ? function (t) { return p.apply(e, t); } : p;
}
export default _superPropGet;
// require() of this module returns the function itself, as the CommonJS helper does.
export { _superPropGet as "module.exports" };
