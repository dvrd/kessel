const asyncFn = async () => {
    await new Promise(resolve => setTimeout(resolve, 100));
};
