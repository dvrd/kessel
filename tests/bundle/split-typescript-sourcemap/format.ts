export type Level = 'info' | 'warn';
interface Unused { never: true }
export function format(level: Level, text: string): string {
  return 'MARK_FORMAT[' + level + '] ' + text;
}
