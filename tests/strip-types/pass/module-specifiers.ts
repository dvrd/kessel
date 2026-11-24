import { "" as empty, "runtime" as runtime, type "model-name" as Model } from "./mixed.js";
import { type Removed } from "./import-side-effect.js";
import fallback, { type Other } from "./with-default.js";
import { type as typeValue } from "./runtime-types.js";
export { type Model, empty, runtime, fallback, typeValue };
export { type "model-name" as "remote model" } from "./export-side-effect.js";
export * as "namespace-name" from "./namespace.js";
export type * as "ignored types" from "./types.js";
