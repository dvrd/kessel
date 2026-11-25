import { logged, sealed, calls } from './decorators';
@sealed
class Service {
  @logged
  greet(name: string): string { return 'hello ' + name; }
  @logged
  static version(): number { return 2; }
}
const service = new Service();
console.log(service.greet('x'), Service.version(), calls.join(','), Object.isSealed(Service));
export { Service };
