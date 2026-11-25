// `as` and `satisfies` have relational precedence and associate to the left.
// Each line pairs the bare spelling with the grouping that changes the tree.
declare const a: any, b: any, c: any, T: any;
// Binary: additive, multiplicative, exponent, shift, bitwise.
const add1 = a + b as T;
const add2 = a + (b as T);
const add3 = (a as T) + b;
const mul1 = a * b satisfies T;
const mul2 = a * (b satisfies T);
const mul3 = (a satisfies T) * b;
const pow1 = a ** b as T;
const pow2 = a ** (b as T);
const pow3 = (a as T) ** b;
const shift1 = a >> b as T;
const shift2 = (a as T) >> b;
const bit1 = a & b as T;
const bit2 = a & (b as T);
const bit3 = (a as T) | b;
// Relational, `in` and `instanceof`: same level, left to right.
const rel1 = a > b as T;
const rel2 = a > (b as T);
const rel3 = (a as T) > b;
const rel4 = (a as T) < b;
const rel5 = (a satisfies T) <= b;
const rel6 = a < (b satisfies T);
const in1 = a in b as T;
const in2 = a in (b as T);
const in3 = (a as T) in b;
const inst1 = a instanceof b as T;
const inst2 = a instanceof (b as T);
const inst3 = (a as T) instanceof b;
// Equality and logical: looser than the assertion.
const eq1 = a === b as T;
const eq2 = (a === b) as T;
const eq3 = a as T !== b;
const and1 = a && b as T;
const and2 = (a && b) as T;
const or1 = a as T || b;
const or2 = (a || b) satisfies T;
const nullish1 = a ?? b as T;
const nullish2 = (a ?? b) as T;
// Conditional.
const cond1 = a as T ? b : c;
const cond2 = a ? b as T : c satisfies T;
const cond3 = (a ? b : c) as T;
// Unary, update and await: tighter than the assertion.
const neg1 = -a as T;
const neg2 = -(a as T);
const not1 = !a satisfies T;
const not2 = !(a satisfies T);
const typeof1 = typeof a as T;
const typeof2 = typeof (a as T);
const void1 = void (a as T);
async function waits() {
  const await1 = await a as T;
  const await2 = await (a as T);
  for (const item of a as T) {}
  for (const key in a as T) {}
  for (let i = (a in b) as T; i; ) {}
  for (let i = ((a as T) in b); i; ) {}
}
// Arrow bodies and assignments: looser than the assertion.
const arrow1 = () => a as T;
const arrow2 = (() => a) as T;
const arrow3 = () => ({}) as T;
let target: any;
target = a as T;
(target as T) = a;
const seq = (a, b) as T;
function* gen() { const y = (yield a) as T; yield a as T; }
// Chains of both keywords, and the other assertion forms.
const chain1 = a as T as any satisfies T;
const chain2 = a as (T extends any ? T : never);
const angle1 = <T>a as any;
const angle2 = <T>(a as any);
const angle3 = (<T>a) + b as T;
const angle4 = a < <T>b;
const bang1 = a! as T;
const bang2 = (a as T)!;
const bang3 = (a as T)!.b as T;
const member1 = (a as T).b;
const member2 = a.b as T;
const call1 = (a as T)(b);
const call2 = a(b as T) as T;
const new1 = new (a as T)();
const tpl1 = `${a as T}`;
const spread = [...a as T, ...(b satisfies T)];
const obj = { key: a as T, ...b as T };
