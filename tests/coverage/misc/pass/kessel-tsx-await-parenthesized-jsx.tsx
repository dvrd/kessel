// `await (<></>)` at the top level of a TSX file. Without module syntax the file is a script,
// where `await` is an identifier and this is a call with a JSX fragment as its argument; with
// module syntax it is an AwaitExpression. Reported as a parse failure; Kessel and oxc-parser
// 0.127.0 accept it either way and agree on both trees. Pinned so it stays that way.
await (<></>)
await (<div title="x">{value}</div>);
const element = await (<></>);
