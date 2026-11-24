console.log('math loaded');
let calls = 0;
exports.add = function (a, b) { calls += 1; return a + b; };
exports.calls = () => calls;
