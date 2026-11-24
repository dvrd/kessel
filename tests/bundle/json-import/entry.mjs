import data from './data.json' with { type: 'json' };
import proto from './proto.json' with { type: 'json' };
import { createRequire } from 'node:module';
console.log(data.name, data.list.length, data.nested.deep, Object.keys(proto), Object.getPrototypeOf(proto) === Object.prototype);
export default data;
