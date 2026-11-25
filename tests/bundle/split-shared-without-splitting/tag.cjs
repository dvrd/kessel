console.log('tag loaded');
let calls = 0;
exports.tag = (text) => '<' + text + ':' + (++calls) + '>';
