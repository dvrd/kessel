// JSX supports namespaced identifiers in tag names via the `ns:name`
// form. ESTree: JSXNamespacedName.namespace + .name.
const a = <svg:rect width="10" />;
const b = <xlink:href url="x" />;
