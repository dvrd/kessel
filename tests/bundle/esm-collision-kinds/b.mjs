export class Widget { static kind = 'b'; }
export function make() { const Widget$1 = 'unrelated'; return new Widget(Widget$1); }
export var counter = 2;
export const { label, i = 'b-i' } = { label: 'b-label' };
export default class OnlyInB { who() { return 'b:' + Widget.kind + counter + i; } }
