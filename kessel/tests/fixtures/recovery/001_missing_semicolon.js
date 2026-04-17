// Missing semicolons (ASI deberia funcionar)
const a = 1
const b = 2

function test() {
  return 1
}

if (true) {
  console.log('ok')
}

// This should work with ASI
const obj = {
  a: 1,
  b: 2
}
