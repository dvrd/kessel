// Class expressions in various positions
const A = class { foo() { return 1; } };
const B = class MyClass extends Error { constructor() { super(); } };
const C = class extends Array { static [Symbol.hasInstance]() { return true; } };
const classes = [class { }, class extends Object { }];
const makeClass = () => class { x = 1; };
