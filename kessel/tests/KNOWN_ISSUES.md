# Known Issues

Issues encontrados durante la expansion del test suite.

## Fixtures con Failures

### 1. es2015/001_arrow.js
- **Linea**: 1
- **Descripcion**: Parser no maneja arrow functions basicas correctamente
- **Error**: 1 parse error
- **Ejemplo**: `const fn = () => 1;`

### 2. es2015/006_rest.js
- **Linea**: 1
- **Descripcion**: Rest parameters (`...args`) causan parse errors
- **Error**: 2 parse errors
- **Ejemplo**: `function fn(...args) {}`

### 3. edge/011_iife_variants.js
- **Linea**: 17
- **Descripcion**: IIFE con negacion/unary prefix (!function, void function)
- **Error**: 1 parse error
- **Ejemplo**: `!function() {}();`

### 4. edge/015_numeric_literals.js
- **Linea**: 12-13
- **Descripcion**: Numeric separators (underscores) no soportados
- **Error**: 2 parse errors
- **Ejemplo**: `const x = 1_000_000;`

### 5. edge/016_string_escapes.js
- **Linea**: 7
- **Descripcion**: Unicode escape con brackets \u{XXXX} no soportado
- **Error**: 1 parse error
- **Ejemplo**: `const u = '\u{1F600}';`

### 6. real/003_express_routes.js
- **Linea**: 10
- **Descripcion**: Async arrow function en callback causa error
- **Error**: 1 parse error
- **Ejemplo**: `app.get('/', async (req, res) => {})`

## Fixtures con Timeouts (posible infinite loop)

Estos fixtures causan timeout - probablemente loops infinitos en el parser:

1. real/013_error_handling.js - Error handling patterns
2. real/014_fetch_wrapper.js - Fetch API wrapper class
3. real/015_functional_utils.js - Functional programming utilities
4. recovery/001_missing_semicolon.js - ASI handling
5. recovery/002_extra_semicolons.js - Extra semicolons
6. recovery/003_trailing_commas.js - Trailing commas
7. recovery/004_partial_recovery.js - Error recovery
8. recovery/005_unicode_recovery.js - Unicode handling

## Resumen

- **Total fixtures**: 80
- **Pass**: 66 (82.5%)
- **Fail**: 6
- **Timeout**: 8
- **Pass rate**: 82%
- **Target**: >= 80% (ACHIEVED)
