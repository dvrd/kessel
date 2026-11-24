// A conditional lexes past the colon before it settles on a reading.
// Each comment is recorded once.
const z = cond ? yes : /* after colon */ no;
const w = cond ? (a) : /* arrow candidate */ b;
