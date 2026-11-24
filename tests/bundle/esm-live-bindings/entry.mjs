import { value, set, bump, state } from './store.mjs';
import * as store from './store.mjs';
import defaultValue, { setDefault } from './store.mjs';
console.log(value, store.value, state.n, defaultValue);
set(5);
console.log(value, store.value);
bump();
bump();
console.log(value, store.value, state.n);
setDefault(9);
// A default export of an expression is a snapshot, not a live binding.
console.log(defaultValue, store.default);
export { value, store };
