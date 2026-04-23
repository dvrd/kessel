#!/usr/bin/env node
// Lexical: UTF-8 BOM (U+FEFF encoded as 0xEF 0xBB 0xBF) at the very
// start of the file, immediately followed by a hashbang line. The BOM
// must be skipped before tokenisation begins, AND the hashbang must be
// captured on `Program.hashbang` rather than as a comment or statement.
// The subsequent source is plain ES script syntax.
const x = 1;
