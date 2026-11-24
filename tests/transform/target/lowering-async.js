// Target lowering inside async functions and async generators, for targets
// that have them. As in lowering.js, the log of the file run as written is
// the specification for every lowered output.
const log = [];
const later = value => new Promise(resolve => setTimeout(() => resolve(value), 1));
const settle = async (label, compute) => {
  try { log.push(label + " = " + JSON.stringify(await compute())); } catch (error) { log.push(label + " throws " + error.constructor.name); }
};
const source = { value: 1, nested: { run(input) { return this === source.nested ? input : "lost"; } }, none: null };

async function awaits() {
  return [
    (await later(null)) ?? "fallback",
    (await later(source))?.value,
    source.none?.[await later("skipped")],
    source?.nested.run(await later("argument")),
    await source.nested?.run?.(later("promised")),
    (await later(source.none))?.value.deeper ?? (await later("chained")),
  ];
}

async function assigns() {
  const box = { count: 0, label: null };
  box.count ||= await later(5);
  box.label ??= await later("named");
  box.count &&= (await later(box.count)) * 5;
  (await later(box)).extra ??= box.missing?.value ?? "extra";
  return box;
}

// Two activations interleave at every await and must not share a value.
async function interleaved(name, delay) {
  const pick = async value => { await later(0); for (let i = 0; i < delay; i += 1) await later(0); return value; };
  return ((await pick({ name }))?.name ?? "none") + "/" + ({ name }).name?.toUpperCase();
}

async function* stream(items) {
  for (const item of items) yield (await later(item))?.id ?? "missing";
}

async function main() {
  await settle("awaits", awaits);
  await settle("assigns", assigns);
  await settle("interleaved", () => Promise.all([interleaved("a", 3), interleaved("b", 1), interleaved("c", 2)]));
  await settle("stream", async () => { const seen = []; for await (const id of stream([{ id: 1 }, null, {}])) seen.push(id); return seen; });
  await settle("rejects", async () => (await later(undefined)).value?.x);
  console.log(log.join("\n"));
}
main();
