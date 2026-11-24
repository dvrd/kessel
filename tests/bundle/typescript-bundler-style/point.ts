export class Point {
  constructor(public x: number, private readonly y: number) {}
  sum(): number { return this.x + this.y; }
}
