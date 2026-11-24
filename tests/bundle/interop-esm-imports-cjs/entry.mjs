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
// Node lists module.exports itself next to the detected names.
console.log(Object.keys(ns).sort(), ns['module.exports'] === whole);
whole.named = 'mutated';
console.log(whole.named);
export { whole, fn };
