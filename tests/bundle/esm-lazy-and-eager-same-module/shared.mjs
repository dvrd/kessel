console.log('shared evaluated');
export const state = { count: 0 };
export function touch() { state.count += 1; }
