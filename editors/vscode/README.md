# Kessel for VS Code

Kessel checks JavaScript, JSX, TypeScript and TSX as you edit. Parser errors
and lint diagnostics appear in the Problems panel. The extension includes the
language server and native library for its target platform.

Open **Extensions: Install from VSIX** in the Command Palette and select the
package for your operating system and architecture. Open a supported file to
start the server. It reads the same project configuration as `kessel lint`,
including nested `kessel.lint.json` and `.oxlintrc.json` files.

Place the cursor on a warning and choose **Quick Fix** to apply its safe
edit. For example, on a `prefer-const` warning, the action changes the
declaration's `let` keyword to `const`.

When `react/exhaustive-deps` is enabled, **Quick Fix** also offers edits to
the dependency list. Select a suggestion to add missing values, remove a
reported entry or create a list for an inline memo callback. Each suggestion
runs only when selected because the edit can change when the callback runs.

**Disable … for this line** inserts a rule-specific directive at a syntax
boundary. **Disable … for this file** inserts a directive at the top of the
file, after a hashbang or byte order mark. Existing enable directives still
take effect. These actions run when you select them in the Quick Fix menu.

Choose **Format Document With…** and select **Kessel** to format imports,
named re-exports, export lists and nested object and array literals in the
open buffer. Data literals can appear in a single-name variable declaration
or a default export. Kessel uses the editor’s tab size, indentation and line
endings. It preserves statements containing internal comments and leaves
incomplete syntax alone while you type.

To apply safe fixes when you explicitly save a document, add this to your VS Code settings.

```json
{
  "editor.codeActionsOnSave": {
    "source.fixAll.kessel": "explicit"
  }
}
```

Use `kessel.rules` to override rule settings for an editor window. For example,
`"kessel.rules": { "prefer-const": "warn" }` highlights bindings that qualify
for a safe conversion. Set `kessel.reportUnusedDisableDirectives` to `"warn"`
to find unused suppression comments.

## Building from the Kessel repository

Build the native library for the host platform and run `task build:vscode`.
The resulting VSIX is in `bin/`. The packaging tools require Node.js 22 or later.
