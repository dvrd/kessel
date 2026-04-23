// Try/catch body with a malformed declaration.
try {
  run();
} catch (err) {
  const broken = 1 + * 2;
}
const anchor_after_error = 1;
