// Extra semicolons (ASI tolerance)
const a = 1;;;
const b = 2;;

function test() {
  return 1;;
}

;;;

if (true) {
  console.log('ok');;
}

const obj = {
  a: 1;;;
  b: 2
};
