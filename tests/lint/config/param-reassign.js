function mutate(param, values) {
  param += 1;
  param++;
  [param] = values;
  for (param of values) {
    consume(param);
  }
  return param;
}
