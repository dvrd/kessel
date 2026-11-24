export let value = 1;
export const state = { n: 0 };
export function set(next) { value = next; }
export function bump() { value++; state.n++; }
let current = 7;
export default current;
export function setDefault(next) { current = next; }
