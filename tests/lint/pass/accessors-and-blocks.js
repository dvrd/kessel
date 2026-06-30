// Negative-space coverage: none of the default-on rules should fire here.
//   - no-dupe-keys: a get/set accessor PAIR with the same name is legal.
//   - no-empty: every block has at least one statement.
//   - no-debugger: no `debugger` statement.
const store = {
  _value: 0,
  get value() {
    return this._value;
  },
  set value(v) {
    this._value = v;
  },
};

function use(s) {
  if (s.value > 0) {
    return s.value;
  }
  return 0;
}

use(store);
