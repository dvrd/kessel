import whole from './plain.cjs';
import { named, other } from './plain.cjs';
import * as ns from './plain.cjs';
import flagged, { value } from './flagged.cjs';
import fn from './function.cjs';
import prim from './primitive.cjs';
console.log(whole.named, named, other, ns.named, ns.default === whole);
// Node ignores __esModule: the default import is module.exports itself.
console.log(typeof flagged, flagged.default, flagged.value, value);
console.log(fn(), fn.label, prim);
// Node lists module.exports itself next to the detected names, from Node 23
// on; the bundle always does. Before 23 only the detected names compare.
const listsModuleExports = typeof process !== 'object' || Number(process.versions.node.split('.')[0]) >= 23;
console.log(Object.keys(ns).filter(key => listsModuleExports || key !== 'module.exports').sort(),
  !listsModuleExports || ns['module.exports'] === whole);
whole.named = 'mutated';
console.log(whole.named);
export { whole, fn };
