// TS generic type-parameter constraint is malformed.
function id<T extends >(x: T): T { return x; }
const anchor_after_error = 1;
