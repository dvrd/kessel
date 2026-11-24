export enum Values {
  Base = 10,
  Next = Base + 1,
  Shadowed = ((Base: number): number => Base + 1)(3),
  Default = ((value: number = Base): number => {
    const Base = 18;
    return value + Base;
  })(),
  Text = "test",
  Alias = Text,
}
export enum Values { Merged = Next - 5 }
if (Values.Next !== 11 || Values.Shadowed !== 4 || Values.Default !== 28) throw new Error("enum scope");
if (Values.Alias !== "test" || Values.Merged !== 6) throw new Error("enum declaration merging");
export declare enum Ambient { Member }

enum Collision {
  Count = 1,
  SameName = ((Collision: number): number => Count + Collision)(42),
  Shorthand = ((): number => ({ Count }).Count)(),
  EscapedName = ((\u005f_kessel_enum_3: number): number => Count + \u005f_kessel_enum_3)(5),
}
if (Collision.SameName !== 43 || Collision.Shorthand !== 1 || Collision.EscapedName !== 6) throw new Error("enum reference capture");
