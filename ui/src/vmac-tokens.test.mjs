import test from "node:test";
import assert from "node:assert/strict";
import { tokens, contrast } from "./vmac-tokens.mjs";

test("VMac has one palette: light", () => {
  assert.deepEqual(Object.keys(tokens), ["light"]);
});
test("brand values match the spec", () => {
  assert.equal(tokens.light.accent, "#3964FE");
  assert.equal(tokens.light.ink, "#0F1115");
  assert.equal(tokens.light.page, "#FFFFFF");
});
test("contrast follows WCAG", () => {
  assert.equal(Math.round(contrast("#000000", "#FFFFFF")), 21);
  assert.equal(contrast("#3964FE", "#3964FE"), 1);
});
for (const mode of ["light"]) {
  const t = tokens[mode];
  // Values, headings and running text keep 4.5:1. The name of a row is in
  // DeepSeek's label grey (tertiary), which is 3.7:1 on the page; the caption
  // step is for placeholders.
  const pairs = [["ink", "page"], ["ink", "chrome"], ["ink", "fill"], ["ink", "accentSoft"], ["secondary", "page"],
    ["secondary", "fill"], ["accentText", "page"], ["onAccent", "accentFill"]];
  for (const [text, surface] of pairs) {
    test(`${mode}: ${text} on ${surface} is at least 4.5:1`, () => {
      assert.ok(contrast(t[text], t[surface]) >= 4.5, `${t[text]} on ${t[surface]}`);
    });
  }
}
// DeepSeek's red sits a little under 4.5:1; a failure always carries a mark
// beside its words, and the red still clears the 3:1 that a mark needs.
test("the failure red stays visible", () => {
  assert.ok(contrast(tokens.light.bad, tokens.light.page) >= 3);
});
test("a row's name stays readable in the label grey", () => {
  assert.ok(contrast(tokens.light.tertiary, tokens.light.page) >= 3.5);
});
test("the values are DeepSeek's", () => {
  const t = tokens.light;
  assert.deepEqual([t.chrome, t.fill, t.secondary, t.tertiary, t.accentSoft, t.accentFillHover, t.ok, t.okSoft],
    ["#F9FAFB", "#F1F3F5", "#61666B", "#81858C", "#E4EDFD", "#5686FE", "#22C55E", "#E6FAED"]);
});
