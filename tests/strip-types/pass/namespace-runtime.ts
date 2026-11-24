const initialization: number[] = [];
function record(value: number): number {
  initialization.push(value);
  return value;
}

export namespace Box {
  export let value = record(2), extra = record(value + 3);
  export let unset: number;
  export const { first: renamed, missing = 6, nested: [item], ...rest } = {
    first: 4,
    missing: undefined,
    nested: [7],
    kept: 8,
  };
  const hidden = 10;
  export function bump(this: void, delta = value) {
    value += delta;
    return value + hidden;
  }
  export class Counter {
    static get value() { return value; }
  }
  export enum Mode { Off = 1, On = Off + 1 }
  export namespace Inner {
    export const snapshot = value;
  }
  export import Alias = Inner;
  namespace Local {
    export const secret = hidden;
  }
  export const secret = Local.secret;
}

export namespace Box {
  export const initial = value + extra + Counter.value;
  export enum Mode { Other = On + value }
  export namespace Inner {
    export const fromEarlier = snapshot + value;
  }
  export function read() {
    {
      function value() { return 90; }
      if (value() !== 90) throw new Error("block function shadowing");
    }
    const shadowed = (value: number) => value + 1;
    return { value, shadowed: shadowed(30), previous: Alias.snapshot };
  }
  export function replace(input: { value?: number }) {
    ({ value = 12 } = input);
  }
}
export namespace Box.Inner.Deep {
  export const snapshot = 20;
}
export namespace Types {
  export interface Item { name: string }
  export type Count = number;
}
export declare namespace Ambient {
  const value: number;
}

export class Widget {}
export namespace Widget { export const label = "widget"; }
export enum Flag { Up }
export namespace Flag { export const label = "flag"; }

if (initialization.join() !== "2,5" || Box.initial !== 9) throw new Error("namespace initialization");
if (Box.renamed !== 4 || Box.missing !== 6 || Box.item !== 7 || Box.rest.kept !== 8) throw new Error("namespace destructuring");
if (Object.hasOwn(Box, "unset") || Object.hasOwn(Box, "Local") || Box.secret !== 10) throw new Error("private namespace bindings");
if (Box.bump(3) !== 15 || Box.Counter.value !== 5) throw new Error("mutable namespace export");
const reading = Box.read();
if (reading.value !== 5 || reading.shadowed !== 31 || reading.previous !== 2) throw new Error("namespace references");
if (Box.Inner.fromEarlier !== 4 || Box.Inner.Deep.snapshot !== 20 || Box.Mode.Other !== 4) throw new Error("namespace merging");
if (Widget.label !== "widget" || Flag.label !== "flag" || Flag[0] !== "Up") throw new Error("runtime declaration merging");
Box.replace({});
if (Box.read().value !== 12) throw new Error("destructuring assignment");
