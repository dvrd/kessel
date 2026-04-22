const data = await fetch("/api");
const json = await data.json();
export { json };
