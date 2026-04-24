// ECMA-262 §15.9.1 final clause: "All early error rules for
// ArrowFormalParameters and their derived productions also apply to
// CoverCallExpressionAndAsyncArrowHead when that production covers an
// AsyncArrowHead." §15.3.1's YieldExpression ban therefore applies to
// async arrow params too. The outer generator legally parses `yield 1`
// as a YieldExpression, but the moment `=>` commits the cover to an
// async-arrow-head the param-yield ban fires. Walker runs post-params.
function* outer() {
  return async (x = yield 1) => x;
}
