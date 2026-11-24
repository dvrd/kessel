import * as ns from './values.mjs';
import * as empty from './empty.mjs';
console.log(Object.keys(ns), ns[Symbol.toStringTag], Object.getPrototypeOf(ns), Object.keys(empty));
console.log('a' in ns, 'missing' in ns, ns.missing, Object.isExtensible(ns));
try { ns.a = 2; } catch (error) { console.log(error.name); }
try { ns.added = 2; } catch (error) { console.log(error.name); }
const { a, b: { c } } = ns;
console.log(a, c, JSON.stringify(ns));
function take(space) { return space.a + space.z; }
console.log(take(ns));
ns.bump();
console.log(ns.a);
