import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { tokens } from "./vmac-tokens.mjs";

const css = readFileSync(new URL("./vmac-theme.css", import.meta.url), "utf8");
const block = selector => css.slice(css.indexOf(selector)).split("}")[0].toLowerCase();
const has = (text, name, value) => text.includes(`${name}: ${value.toLowerCase()}`);

test("light variables come from the tokens", () => {
  const light = block(":root.vmac-theme {");
  for (const [name, key] of [["--paper", "page"], ["--chrome", "chrome"], ["--ink", "ink"], ["--muted", "muted"],
    ["--accent", "accent"], ["--button", "accentFill"], ["--link", "accentText"], ["--danger", "badText"]]) {
    assert.ok(has(light, name, tokens.light[key]), `${name} should be ${tokens.light[key]}`);
  }
});
test("dark variables come from the tokens", () => {
  const dark = block(':root.vmac-theme[data-vmac-appearance="dark"]');
  for (const [name, key] of [["--paper", "page"], ["--ink", "ink"], ["--accent", "accent"], ["--link", "accentText"]]) {
    assert.ok(has(dark, name, tokens.dark[key]), `${name} should be ${tokens.dark[key]}`);
  }
});
test("no stylesheet keeps the retired palette", () => {
  const retired = /#a64d2f|#933f24|#faf9f5|#fffefb|#f0eee7|#e8e5db|#dcd7cb|#716d64|#527052|#a43830|#b2741d|166, 77, 47|38, 38, 36/i;
  const dir = new URL(".", import.meta.url);
  for (const file of readdirSync(dir).filter(name => name.endsWith(".css"))) {
    const text = readFileSync(new URL(file, dir), "utf8");
    assert.ok(!retired.test(text), `${file} still uses a retired color`);
  }
});

test("dark looks the same whether the system or the setting chose it", () => {
  const values = text => text.slice(text.indexOf("{") + 1).replace(/\s+/g, " ").trim();
  const chosen = css.slice(css.indexOf(':root.vmac-theme[data-vmac-appearance="dark"]')).split("}")[0];
  const system = css.slice(css.indexOf(':root.vmac-theme:not([data-vmac-appearance="light"])')).split("}")[0];
  assert.equal(values(system), values(chosen));
});
test("the appearance setting reaches the VMac theme", () => {
  const source = readFileSync(new URL("./appearance.jsx", import.meta.url), "utf8");
  assert.match(source, /dataset\.vmacAppearance = variant/);
});
