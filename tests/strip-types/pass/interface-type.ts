// Interfaces and type aliases have no runtime and are removed whole.
interface Point {
  x: number;
  y: number;
}
type ID = string | number;
type Handler = (e: Point) => void;
const origin = { x: 0, y: 0 };
