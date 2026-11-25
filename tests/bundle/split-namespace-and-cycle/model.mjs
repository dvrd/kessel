import { describe } from './describe.mjs';
export let kind = 'initial';
export function setKind(next) { kind = next; self.kind = next; }
const self = { kind };
export default self;
console.log('model evaluated', describe());
export function late() {}
