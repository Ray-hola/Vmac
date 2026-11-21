import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { pageGroups, pages, placeName } from "./vmac-pages.mjs";

test("the native sidebar lists the same pages in the same order", () => {
  const swift = readFileSync(new URL("../../desktop/GuestSidebar.swift", import.meta.url), "utf8");
  const block = swift.slice(swift.indexOf("// sidebar-pages:begin"), swift.indexOf("// sidebar-pages:end"));
  const rows = [...block.matchAll(/\("([\w-]+)", "([^"]+)", "([\w.]+)", "([^"]*)"\)/g)].map(match => match.slice(1));
  const expected = pageGroups.flatMap(group => group.pages.map(id => [id, pages[id].title, pages[id].symbol, group.label]));
  assert.deepEqual(rows, expected);
});

// Messages from the backend and the launcher point at pages by name too.
test("the backend names the same pages in its messages", () => {
  const go = readFileSync(new URL("../../internal/version/places.go", import.meta.url), "utf8");
  for (const section of ["account", "network"]) {
    assert.ok(go.includes(`"「${placeName(section, true)}」"`), `places.go should name ${placeName(section, true)}`);
    assert.ok(go.includes(placeName(section, false)), `places.go should keep ${placeName(section, false)} for the shared workbench`);
  }
});
test("no hint in the pages or the launcher names a place by its old name", () => {
  const old = /设置 → 账户|网络与代理设置|虚拟机管理/;
  const here = new URL("./", import.meta.url);
  for (const name of readdirSync(here).filter(file => file.endsWith(".jsx"))) {
    assert.doesNotMatch(readFileSync(new URL(name, here), "utf8"), old, `${name} names an old place`);
  }
  assert.doesNotMatch(readFileSync(new URL("../../desktop/Cage.swift", import.meta.url), "utf8"), old, "Cage.swift names an old place");
});

