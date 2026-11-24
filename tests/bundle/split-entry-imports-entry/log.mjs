const seen = [];
export function log(name) { seen.push(name); console.log('log', seen.join('>')); }
