import { state, touch } from './shared.mjs';
import './side.mjs';
console.log('entry', state.count);
touch();
const again = await import('./shared.mjs');
console.log(again.state === state, again.state.count, Object.keys(again));
