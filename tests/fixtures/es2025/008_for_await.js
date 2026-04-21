async function consume() {
    for await (const val of gen()) {
        console.log(val);
    }
}
