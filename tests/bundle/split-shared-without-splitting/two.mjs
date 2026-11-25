import * as reg from './registry.mjs';
import data from './data.json' with { type: 'json' };
reg.register('two');
console.log('two', reg.registry.join(','), data.label, Object.keys(reg).join(','));
const late = await import('./late.mjs');
console.log(late.default, reg.registry.join(','));
