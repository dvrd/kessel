// Template literal escapes. `raw` preserves the backslash sequences,
// `cooked` decodes them. ESTree: TemplateElement.value = {cooked, raw}.
const t1 = `a\nb`;            // cooked: "a\nb", raw: "a\\nb"
const t2 = `x${1}y\tz`;       // mixed with interpolation
const t3 = `\u0041\x42`;      // unicode + hex escapes cook normally
const t4 = `\`backtick\``;    // escaped backtick
