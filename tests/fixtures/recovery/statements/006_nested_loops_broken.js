// Inner for-loop header is malformed; the anchor must survive despite
// the nested block body still being parsed for recovery.
for (let i = 0; i < 10; i++) {
  for (let j = ; j < 10; j++) {
    break
  }
}
const anchor_after_error = 1;
