export const value = 'a';
export function read() { return value; }
const console$1 = 'not the global';
export default function helper() { return console$1 + ':' + process(1); }
function process(n) { return n + 1; }
