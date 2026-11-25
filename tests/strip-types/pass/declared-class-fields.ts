const key = Symbol("field");
class Base {
  value = 7;
  static flag = 11;
}
class Derived extends Base {
  declare value: number;
  declare static flag: number;
  declare readonly [key]: string;
  declare: number = 9;
}
const instance = new Derived();
if (instance.value !== 7 || Derived.flag !== 11) throw Error("lost inherited value");
if (Object.hasOwn(Derived, "flag") || Object.hasOwn(instance, key)) throw Error("declared field emitted");
if (instance.declare !== 9) throw Error("ordinary field named declare erased");
