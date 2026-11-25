export type Shape = { kind: 'square'; size: number } | { kind: 'circle'; radius: number };
export function area(shape: Shape): number {
  switch (shape.kind) {
    case 'square': return shape.size ** 2;
    case 'circle': return Math.PI * shape.radius ** 2;
  }
}
interface Internal { hidden: true }
