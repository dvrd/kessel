// TS declaration statements that the raw_transfer binary walker previously left
// un-handled: with rewrite_statement converted to a complete switch (no #partial,
// no default), TSImportEqualsDeclaration (both the require() external-module-
// reference arm and the qualified-name expression arm), TSExportAssignment, and
// TSNamespaceExportDeclaration now have explicit cases that rewrite their inner
// id / module-reference / expression pointers in the binary buffer.
import fs = require("fs");
import ns = A.B.C;
export = fs;
export as namespace MyLib;
