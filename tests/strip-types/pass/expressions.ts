// TS-only expressions unwrap to their operand.
const widget = load() as Widget;
const config = data satisfies Config;
const value = maybe!.field;
const forced = <Foo>bar;
const chained = svc!.get() as Result;
