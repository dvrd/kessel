export class Widget { static kind = 'a'; static self() { return Widget; } }
export function make() { return new (Widget.self())(); }
export var counter = 1;
export const [label] = ['a-label'];
for (var i = 0; i < 3; i++) counter += i;
var i;
export default class OnlyInA { who() { return 'a:' + Widget.kind + counter + i; } }
