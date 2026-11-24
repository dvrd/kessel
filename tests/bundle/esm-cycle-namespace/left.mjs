import * as right from './right.mjs';
export const name = 'left';
export function other() { return right.name; }
export function early() { return 'early-left'; }
