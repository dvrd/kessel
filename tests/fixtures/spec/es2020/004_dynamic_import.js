async function load(name) {
  const mod = await import(`./${name}.js`);
  return mod.default;
}
