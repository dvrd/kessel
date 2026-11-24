import { typed, type Shape } from './typed.ts';
import legacy from './legacy.cjs';
import { plain } from './plain.mjs';

interface Padding { lines: number; that: string; shift: boolean }

console.log('MARK_ENTRY_FIRST', typed(2), legacy.run(), plain());
const shape: Shape = { kind: 'MARK_ENTRY_OBJECT' };
export function later(): string {
  const value: string = 'MARK_ENTRY_NESTED';
  return value + shape.kind;
}
console.log(later());
