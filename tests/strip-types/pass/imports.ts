// Type-only imports and exports, and ambient declarations, are removed.
import type { Widget } from "./widget";
import { load } from "./loader";
export type { Widget };
export { load };
declare const GLOBAL_FLAG: boolean;
declare function externalHook(): void;
