// TS import type versus runtime dynamic import.
import type { Foo } from "./foo";
const mod = import("./foo");
