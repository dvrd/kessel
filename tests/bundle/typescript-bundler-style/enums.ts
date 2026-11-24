export enum Color { Red, Green, Blue }
export const enum Direction { Up = 'UP', Down = 'DOWN' }
export function describe(color: Color): string { return `color:${Color[color]}`; }
