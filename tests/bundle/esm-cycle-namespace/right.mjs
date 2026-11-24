import * as left from './left.mjs';
// left.mjs has not evaluated: functions work, const bindings are in TDZ.
console.log('right sees', left.early(), typeof left.other);
try { left.name; } catch (error) { console.log('tdz', error.name); }
export const name = 'right';
