import * as model from './model.mjs';
// A cycle inside the shared chunk: `kind` is in TDZ the first time.
export function describe() {
  try { return 'kind=' + model.kind; } catch (error) { return error.name; }
}
