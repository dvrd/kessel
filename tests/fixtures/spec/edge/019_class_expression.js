const Foo = class {};
const Bar = class BarNamed { constructor() {} };
const baz = new (class { method() { return 1; } })();
