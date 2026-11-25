// Stand-in for the helper of the same name in @oxc-project/runtime, which the
// pinned bench packages do not include. Written after the Babel helper; an
// ES module, so it is strict code as the published ESM helper is.
function asyncGeneratorStep(n, t, e, r, o, a, c) {
  try { var i = n[a](c), u = i.value; } catch (n) { return void e(n); }
  i.done ? t(u) : Promise.resolve(u).then(r, o);
}
function _asyncToGenerator(n) {
  return function () {
    var t = this, e = arguments;
    return new Promise(function (r, o) {
      var a = n.apply(t, e);
      function _next(n) { asyncGeneratorStep(a, r, o, _next, _throw, "next", n); }
      function _throw(n) { asyncGeneratorStep(a, r, o, _next, _throw, "throw", n); }
      _next(void 0);
    });
  };
}
export default _asyncToGenerator;
// require() of this module returns the function itself, as the CommonJS helper does.
export { _asyncToGenerator as "module.exports" };
