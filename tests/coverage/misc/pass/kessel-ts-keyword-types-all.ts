// Exercises every TS keyword type plus `this` type, all of which collapse
// into a single TSKeywordType node tagged by kind. Locks in that each kind
// still round-trips to its distinct TS-ESTree node type.
let a: any;
let b: bigint;
let c: boolean;
let d: never;
let e: null;
let f: number;
let g: object;
let h: string;
let i: symbol;
let j: undefined;
let k: unknown;
let l: void;
type Pred<T> = T extends string ? true : false;
type Intr = intrinsic;
class C {
	m(): this {
		return this;
	}
}
