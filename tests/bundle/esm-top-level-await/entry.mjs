import { ready } from './dep.mjs';
console.log('before await', ready);
const value = await new Promise(resolve => setTimeout(() => resolve('awaited'), 5));
console.log(value);
for await (const item of (async function* () { yield 1; yield 2; })()) console.log('item', item);
export const result = value.toUpperCase();
