// `import = require(...)` is a runtime binding — not erasable.
import fs = require("fs");
fs.readFileSync("x");
