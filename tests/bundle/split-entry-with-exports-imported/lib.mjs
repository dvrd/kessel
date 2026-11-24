console.log('lib evaluated');
export const version = '1.0';
export function describe() { return 'lib ' + version; }
export default class Lib { name = 'lib-instance'; }
const internal = { n: 1 };
export { internal as 'string name' };
