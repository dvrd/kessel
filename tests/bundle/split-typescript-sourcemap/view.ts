import { counter } from './shared.ts';
export function render(label: string): string {
  return 'MARK_VIEW ' + label + ' ' + counter.n;
}
