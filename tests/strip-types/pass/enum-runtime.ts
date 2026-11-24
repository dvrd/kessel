let calls = 0;
function compute(): number {
  calls++;
  return 42;
}
enum Sizes { Small = 10, Medium, Large = -3, Next }
enum Labels { Text = "label", Empty = "", "quote\"key" = "quoted" }
enum Mixed { Label = "tag", Number = compute(), Explicit = 10, Following }
if (Sizes.Medium !== 11 || Sizes.Next !== -2 || Sizes[-2] !== "Next") throw new Error("numeric progression");
if (Labels.Text !== "label" || Labels.Empty !== "" || Labels['quote"key'] !== "quoted") throw new Error("string members");
if (Object.hasOwn(Labels, "label") || Object.hasOwn(Labels, "") || Object.hasOwn(Mixed, "tag")) throw new Error("string reverse map");
if (Mixed.Number !== 42 || Mixed[42] !== "Number" || Mixed.Following !== 11 || calls !== 1) throw new Error("computed number");
