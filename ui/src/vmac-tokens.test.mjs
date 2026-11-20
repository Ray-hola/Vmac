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
  const pairs = [["ink", "page"], ["ink", "group"], ["muted", "page"], ["muted", "group"],
    ["accentText", "page"], ["accentText", "group"], ["accentText", "accentSoft"],
    ["okText", "group"], ["warnText", "group"], ["badText", "group"], ["onAccent", "accentFill"],
    ["onAccent", "accentFillHover"], ["onAccent", "accentFillActive"]];
  for (const [text, surface] of pairs) {
    test(`${mode}: ${text} on ${surface} is at least 4.5:1`, () => {
      assert.ok(contrast(t[text], t[surface]) >= 4.5, `${t[text]} on ${t[surface]}`);
    });
  }
}
