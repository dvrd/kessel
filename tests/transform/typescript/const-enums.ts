const enum Flags {
  None,
  Read = 1 << 0,
  Write = 1 << 1,
  Both = Read | Write,
  Negative = -2,
  Large = 0xffffffff >>> 1,
  Description = "mask-" + Both,
}
const enum More { Value = Flags["Both"] + 4, Next, Message = `v${Next}` }
const enum Merged { First = 9 }
const enum Merged { Second = First + 1 }
export const enum Public { Banner = "public", Count = 3 }

function shadowed(Flags = { Both: 16 }) { return Flags.Both; }
function nested() {
  const enum Flags { Both = 27 }
  return Flags.Both;
}
const data = [Flags.None, Flags.Both, Flags["Description"], More.Value, More.Next,
  More.Message, Merged.Second, Public.Banner, shadowed(), nested(),
  Flags.Large, Flags.Negative ** 2, Flags.Read.toString(), -Flags.Negative];
const expected = [0, 3, "mask-3", 7, 8, "v8", 10, "public", 16, 27, 2147483647, 4, "1", 2];
if (JSON.stringify(data) !== JSON.stringify(expected)) throw Error(JSON.stringify(data));
console.log(JSON.stringify(data));
