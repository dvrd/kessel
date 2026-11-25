export const calls: string[] = [];
export function logged(target: any, key: string, descriptor: PropertyDescriptor): PropertyDescriptor {
  const original = descriptor.value;
  descriptor.value = function (...args: unknown[]) { calls.push(key); return original.apply(this, args); };
  return descriptor;
}
export function sealed(constructor: Function): void { Object.seal(constructor); }
