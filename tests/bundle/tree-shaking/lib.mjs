export function used() { return 'used'; }
export function unusedFunction() { return 'UNUSED_FUNCTION_BODY'; }
export const unusedValue = 'UNUSED_CONST_VALUE';
const helper = () => 'helper';
const unusedHelper = () => 'UNUSED_HELPER_BODY';
export function chained() { return helper(); }
export class UnusedClass { method() { return 'UNUSED_CLASS_BODY'; } }
export const keptForEffect = console.log('KEPT_SIDE_EFFECT');
const pureCall = /* @__PURE__ */ makeThing('PURE_CALL_ARGUMENT');
function makeThing(label) { return { label }; }
var unusedObject = { a: 1, b: [2, 'UNUSED_OBJECT_VALUE'], c: () => 3 };
