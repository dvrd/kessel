// `export default` followed by a regular expression literal is one statement:
// the slash starts a RegExp, not a division after an empty default export.
export default /^[0-9a-f]{8}-[0-9a-f]{4}$/i;
