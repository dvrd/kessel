import { early, one } from "./module.mjs";
export const events = [];
export function acquire(id) {
  events.push(id);
  return { [Symbol.dispose || Symbol.for("Symbol.dispose")]() { events.push("close-" + id); } };
}
export function readCycle() { return early; }
export function observe() { return one; }
