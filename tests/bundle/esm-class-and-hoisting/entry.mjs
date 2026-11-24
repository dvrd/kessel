import { Base, Derived, make } from './classes.mjs';
const item = make();
console.log(item instanceof Base, item.describe(), Derived.count, Derived.name, Base.name);
try { useBeforeDefine(); } catch (error) { console.log(error.name); }
function useBeforeDefine() { return new Late(); }
class Late {}
console.log(typeof useBeforeDefine());
