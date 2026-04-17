// Partial recovery from errors
const valid1 = 1;
const valid2 = 2;

// The following line has an error but parser should continue
// const bad = #@$;

const valid3 = 3;
const valid4 = 4;

function stillWorks() {
  return 'recovery works';
}

const arr = [
  1,
  2,
  // @#$ <-- error here
  4
];
