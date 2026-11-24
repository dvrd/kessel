export interface Named { name: string }
export class Named { static tag = 'merged-class'; }
export namespace util {
  export const double = (n: number): number => n * 2;
}
