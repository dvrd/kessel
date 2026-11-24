import { add, counter, increment } from './math.mjs';
import greet from './greet.mjs';
console.log('entry', add(1, 2), greet('x'), counter);
increment();
console.log('after increment', counter);
export { add };
export const answer = 42;
export default function main() { return 'main'; }
