// `$` and `_` are explicit IdentifierStart characters regardless of
// the underlying Unicode property.
const $ = 1;
const _ = 2;
const $x = 3;
const _y = 4;
const $$ = 5;
const __ = 6;
const $_ = 7;
const _$ = 8;
