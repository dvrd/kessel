type Child = string | number | Child[];
export const Fragment = 'fragment';
export function h(tag: any, props: Record<string, unknown> | null, ...children: Child[]): string {
  if (typeof tag === 'function') return tag({ ...props, children });
  const attrs = Object.entries(props ?? {}).map(([k, v]) => ` ${k}=${JSON.stringify(v)}`).join('');
  return `<${tag}${attrs}>${children.flat(9).join('')}</${tag}>`;
}
