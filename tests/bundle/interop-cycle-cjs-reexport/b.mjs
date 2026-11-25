import { x, y, whole } from './a.mjs';
console.log('b start');
try { console.log('b reads x', x); } catch (e) { console.log('x:', e.name, e.message); }
try { console.log('b reads whole', whole); } catch (e) { console.log('whole:', e.name, e.message); }
export const later = () => [x, y, whole.x];
