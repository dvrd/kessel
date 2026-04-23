// Switch case with a malformed assignment.
switch (value) {
  case 1:
    const broken = 1 + * 2;
    break;
}
const anchor_after_error = 1;
