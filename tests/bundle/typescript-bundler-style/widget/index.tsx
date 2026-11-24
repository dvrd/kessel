import { h, Fragment } from '../jsx';
import { Label } from './label';
export default function Widget() {
  return <section id="w"><Label text="hi" /><>{[1, 2].map(n => <i key={n}>{n}</i>)}</></section>;
}
