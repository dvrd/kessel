import { Widget as A, make as makeA, counter as counterA, label as labelA } from './a.mjs';
import { Widget as B, make as makeB, counter as counterB, label as labelB } from './b.mjs';
import DefaultA from './a.mjs';
import DefaultB from './b.mjs';
class Widget { static kind = 'entry'; }
function make() { return new Widget(); }
var counter = 100;
const [label, { nested: inner = 'fallback' }] = ['entry-label', {}];
console.log(Widget.kind, A.kind, B.kind, make() instanceof Widget, makeA() instanceof A, makeB() instanceof B);
console.log(counter, counterA, counterB, label, labelA, labelB, inner, new DefaultA().who(), new DefaultB().who());
// Class and function names are observable; colliding ones are renamed in a
// bundle, so only compare names that no other module declares.
console.log(DefaultA.name, DefaultB.name);
export { Widget, make, counter, label };
