// ArrowFunction[In] : ArrowParameters => ConciseBody[?In]. An expression body
// inherits the for-head restriction, so `in` ends the initializer here and the
// head is malformed. Only a block body lifts the restriction.
for (var f = () => "a" in o; ;) {}
