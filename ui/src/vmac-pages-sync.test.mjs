import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pageGroups, pages } from "./vmac-pages.mjs";

test("the native sidebar lists the same pages in the same order", () => {
  const swift = readFileSync(new URL("../../desktop/GuestSidebar.swift", import.meta.url), "utf8");
  const block = swift.slice(swift.indexOf("// sidebar-pages:begin"), swift.indexOf("// sidebar-pages:end"));
  const rows = [...block.matchAll(/\("([\w-]+)", "([^"]+)", "([\w.]+)", "([^"]*)"\)/g)].map(match => match.slice(1));
  const expected = pageGroups.flatMap(group => group.pages.map(id => [id, pages[id].title, pages[id].symbol, group.label]));
  assert.deepEqual(rows, expected);
});
