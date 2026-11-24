import { who, counter, bump } from './lib.cjs';
import lib from './lib.cjs';
import * as ns from './lib.cjs';
// Calling an imported binding never passes the module object as `this`.
console.log(who(), lib.who(), ns.who() === ns ? 'namespace' : 'other', who?.(), who`t`);
console.log(new who.Maker().made, typeof who.call);
bump();
bump();
// Node snapshots named exports of CommonJS; the object behind them stays live.
console.log(lib.counter, typeof counter);
