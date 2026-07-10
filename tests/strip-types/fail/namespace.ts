// A namespace with a runtime body compiles to an IIFE — not erasable.
namespace Geometry {
  export const PI = 3.14;
  export function circle(r: number) {
    return PI * r * r;
  }
}
