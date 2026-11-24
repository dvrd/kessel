export type Shape = { kind: string };
type Erased = { a: number; b: string };

export function typed(n: number): string {
  const doubled: number = n * 2;
  return 'MARK_TYPED_RETURN' + doubled;
}
