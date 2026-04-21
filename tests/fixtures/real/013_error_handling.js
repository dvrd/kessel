// Error handling patterns
class ValidationError extends Error {
  constructor(fields) {
    super('Validation failed');
    this.name = 'ValidationError';
    this.fields = fields;
    this.statusCode = 400;
  }
}

function assertNotNull(value, message) {
  if (value == null) {
    throw new TypeError(message || 'Expected non-null value');
  }
  return value;
}

try {
  const data = JSON.parse(input);
} catch (err) {
  if (err instanceof SyntaxError) {
    console.error('Invalid JSON:', err.message);
  } else {
    throw err;
  }
}
