export default 7;
export function fn() { return this === undefined ? 'no-this' : 'has-this'; }
export class Base { base = 'base-field'; }
export const key = 'k';
export const tag = (strings, ...values) => strings.raw.join('|') + values.join(',');
export const obj = { inner: { fn() { return this === obj.inner ? 'receiver' : 'detached'; } }, temp: 1 };
export const list = [7, 8, 9];
