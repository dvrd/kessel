import { area, type Shape } from './shapes.ts';
import type { Unused } from './types.ts';
import { label } from './label.ts';
const square: Shape = { kind: 'square', size: 3 };
const result: number = area(square);
console.log(label<string>('area'), result satisfies number, area({ kind: 'circle', radius: 1 }).toFixed(2));
export const total = result as number;
export type { Shape };
