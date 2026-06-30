// no-dupe-keys (L2002): duplicate data key in an object literal.
// Expected: kessel lint reports the diagnostic and exits 1.
const config = {
  width: 100,
  height: 200,
  width: 300,
};

export { config };
