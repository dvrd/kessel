if (process.env.NODE_ENV !== 'production') {
  exports.mode = 'development-branch';
  return;
}
exports.mode = 'production-branch';
