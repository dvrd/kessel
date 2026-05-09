// TS2389 — overload-chain check applies inside BlockStatement bodies
// (not just at Program top level). Block scope is one binding scope,
// so `function foo();\nfunction bar(){}` inside `{}` reports the
// impl-name mismatch on `bar`.
{
  function foo();
  function bar() {}
}
