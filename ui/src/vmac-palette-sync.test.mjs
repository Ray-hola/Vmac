import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { tokens } from "./vmac-tokens.mjs";

test("the native palette matches the tokens", () => {
  const swift = readFileSync(new URL("../../desktop/VMacPalette.swift", import.meta.url), "utf8");
  const rows = [...swift.matchAll(/dynamic\(0x([0-9A-F]{6}), 0x([0-9A-F]{6})\) \/\/ token: (\w+)/g)];
  assert.ok(rows.length >= 11, "expected every hex member to carry a token name");
  for (const [, light, dark, key] of rows) {
    assert.equal(`#${light}`, tokens.light[key], `light ${key}`);
    assert.equal(`#${dark}`, tokens.dark[key], `dark ${key}`);
  }
});
