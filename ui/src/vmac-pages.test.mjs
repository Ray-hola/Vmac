import test from "node:test";
import assert from "node:assert/strict";
import { pageGroups, pages, pageFor, embeddedSections } from "./vmac-pages.mjs";

const ids = pageGroups.flatMap(group => group.pages);
test("ten pages, each listed once and fully described", () => {
  assert.equal(ids.length, 10);
  assert.equal(new Set(ids).size, 10);
  assert.deepEqual([...ids].sort(), Object.keys(pages).sort());
  for (const id of ids) assert.ok(pages[id].title && pages[id].symbol, id);
});
test("the groups read as in the spec", () => {
  assert.deepEqual(pageGroups.map(group => group.label), ["", "这台客机", "网络", "VMac"]);
  assert.deepEqual(pageGroups[0].pages, ["overview"]);
  assert.deepEqual(pageGroups[3].pages, ["general", "security", "recovery", "about"]);
});
test("every old entry point reaches a page", () => {
  const expected = { lifecycle: "overview", desktop: "overview", space: "machines", profiles: "machines", management: "machines",
    login: "system", timezone: "system", input: "system", region: "system", network: "proxy", settings: "general",
    keyboard: "general", appearance: "general", account: "security", vault: "security", mobile: "security",
    project: "recovery", "archived-sessions": "recovery", about: "about", proxy: "proxy", checks: "checks" };
  for (const [from, to] of Object.entries(expected)) assert.equal(pageFor(from), to, from);
  assert.equal(pageFor("nonsense"), "overview");
  for (const id of ids) assert.equal(pageFor(id), id);
});
test("each old settings section is embedded in exactly one page", () => {
  const sections = ids.flatMap(id => embeddedSections(id));
  assert.deepEqual([...sections].sort(), ["about", "account", "appearance", "archived-sessions", "keyboard", "mobile", "network", "project", "region", "vault"]);
  assert.deepEqual(embeddedSections("overview"), []);
});
