import { renamed, ns, viaImport, deep, value as v } from './middle.mjs';
console.log(renamed, Object.keys(ns), ns.value, viaImport, deep, v);
export { renamed as again, ns };
export * as everything from './middle.mjs';
