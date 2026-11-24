export * from './one.mjs';
export * from './two.mjs';
export * from './again.mjs';
export const local = 'barrel-local';
// A local export wins over the same name coming through a star.
export const two = 'barrel-two';
