import { first } from './first.mjs';
export function readFirst() { return first; }
try {
  console.log(first);
} catch (error) {
  console.log('second caught', error.name, error.message);
}
export const second = 'second-value';
