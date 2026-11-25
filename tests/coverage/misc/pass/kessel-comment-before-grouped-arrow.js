// A comment after the opening parenthesis does not ungroup the arrow.
x = a > (/* c */ () => T) > T;
y = a || (// c
  () => 1);
z = !(/* c */ () => 1);
