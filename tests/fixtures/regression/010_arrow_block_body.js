// Regression: parse_arrow_function (3 sites) stored the arrow body via
//   body = cast(^BlockStatement)block_stmt
// where block_stmt is a ^Statement union pointer. This is Bug H class UB:
// the Statement union's 16-byte header was read as the start of the
// BlockStatement struct fields, so `body.body` ended up iterating garbage
// memory. At emit time, print_block_statement_inline would fetch garbage
// ^Statement pointers (observed values like 0x14 = 20) from the bad
// [dynamic]^Statement backing store and SIGSEGV inside
// get_statement_type_name's type-switch dispatch.
//
// Latent until ClassBody JSON emit was enabled this session — previously
// the `"body": []` stub stopped the walk before reaching class method
// bodies that contained arrow expressions with block bodies. Reproduced
// on 12 real-world files: tone.js, mathjax.js, marked.js, chartjs.js,
// quill.js, embla.js, mapbox.js, openlayers.js, framer-motion.js,
// lit-html.js, petite-vue.js, prettier.js.
//
// Fixed at all three arrow-function parse sites (multi-param arrow,
// single-ident arrow, async arrow) by extracting via type assertion
// `block_stmt^.(^BlockStatement)`.
//
// This fixture exercises all three parse paths:
//   - multi-param arrow with block body:     `(a, b) => { ... }`
//   - single-ident arrow with block body:    `x => { ... }`
//   - async arrow with block body:           `async (x) => { ... }`
// All three are nested inside a class method so the emitter walks
// ClassBody → MethodDefinition → FunctionExpression body → ArrowFunction
// block body, the exact call path that crashed before the fix.

class Regression010 {
  run(items) {
    // multi-param arrow, block body
    const multi = (a, b) => {
      const sum = a + b;
      for (let i = 0; i < 3; i += 1) {
        items.push(sum + i);
      }
      return sum;
    };

    // single-ident arrow, block body
    const single = x => {
      if (x > 0) {
        items.push(x);
        return x * 2;
      }
      return 0;
    };

    // async arrow, block body
    const asyncArrow = async (x) => {
      const y = await Promise.resolve(x);
      items.push(y);
      return y;
    };

    // Expression-body arrows (non-block) in the same spot to ensure the
    // fix didn't regress the non-block path.
    const expr = n => n * 2;
    const exprPair = (a, b) => a + b;

    return [multi, single, asyncArrow, expr, exprPair];
  }
}
