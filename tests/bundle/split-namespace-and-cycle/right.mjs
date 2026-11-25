import model, { kind, setKind } from './model.mjs';
setKind('changed-by-right');
console.log('right', kind, model.kind, model === (await import('./model.mjs')).default);
