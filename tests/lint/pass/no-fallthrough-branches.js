function choose(key, flag) {
  switch (key) {
    case 1:
      if (flag) {
        break;
      } else {
        return 2;
      }
    default:
      return 3;
  }
  return 4;
}

function conditional(flag) {
  if (flag) {
    return 1;
  }
  return 2;
}
