// Interaction: unicode-escape identifiers used as a class name and in a
// method name, alongside a private field (`#id`) in the same body. The
// parser must treat `\u00e9` as an identifier-name character both at
// identifier-start (class name) and identifier-continuation (method name)
// positions, and still recognise `#id` as a private identifier.
//
// The private name itself is kept ASCII because escape sequences inside
// private names are a separate, narrower parser surface and are covered
// elsewhere in `spec/unicode`.
class C\u00e9 {
  #id = 1;
  m\u00e9thod() {
    return this.#id;
  }
}
