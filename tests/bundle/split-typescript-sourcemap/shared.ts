console.log('MARK_SHARED evaluated');
export const counter: { n: number } = { n: 0 };
export function bump(): void { counter.n += 1; }
