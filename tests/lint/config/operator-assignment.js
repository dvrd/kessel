// operator-assignment (L4099, default-off): x = x + 1 could be x += 1.
// Enabled explicitly via --rule so this fixture must report a diagnostic.
let x = 0;
x = x + 1;
