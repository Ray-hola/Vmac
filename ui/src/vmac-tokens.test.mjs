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
  // Text that carries meaning keeps 4.5:1. The tertiary and caption steps
  // are DeepSeek's and stay for labels that repeat what is said elsewhere.
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
test("the values are DeepSeek's", () => {
  const t = tokens.light;
  assert.deepEqual([t.chrome, t.fill, t.secondary, t.tertiary, t.accentSoft, t.accentFillHover],
    ["#F9FAFB", "#F1F3F5", "#61666B", "#81858C", "#E4EDFD", "#5686FE"]);
});
