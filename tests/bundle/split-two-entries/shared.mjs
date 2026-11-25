import './deep.mjs';
console.log('shared evaluated');
export const shared = { count: 0 };
export function bump() { shared.count += 1; }
