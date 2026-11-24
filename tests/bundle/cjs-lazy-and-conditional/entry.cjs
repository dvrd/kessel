console.log('start');
function load(which) { return which ? require('./a.cjs') : require('./b.cjs'); }
console.log(load(true).id);
console.log(load(true).id);
if (process.argv.length > 99) require('./never.cjs');
try { require('./throws.cjs'); } catch (error) { console.log('caught', error.message); }
// Node drops a module that threw from its cache and evaluates it again.
try { require('./throws.cjs'); } catch (error) { console.log('caught again', error.message); }
console.log(load(false).id);
module.exports = 'done';
