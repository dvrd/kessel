// Stand-ins for a Hooks library and higher-order components.
export const useCustom = value => value;
export const useNamespaced = () => "namespaced";
export const useShape = value => ({ a: value.a, b: ["c"] });
export const withTheme = (component, theme) => ({ themed: component, theme });
export const styled = { div: () => function StyledDiv() { return null; } };
export const make = () => function Made() { return null; };
