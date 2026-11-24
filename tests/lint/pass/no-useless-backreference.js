const ordinary = /(a)\1/;
const optional = /(a)?\1/;
const backward = /(?<=\1(a))/;
const named = /(?<x>a)\k<x>/u;
const constructor = new RegExp("(a)\\1");
const nullCharacter = "\0";
function shadowed(RegExp) {
  return RegExp("\\1(a)");
}
