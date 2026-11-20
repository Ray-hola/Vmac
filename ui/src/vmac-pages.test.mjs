import test from "node:test";
import assert from "node:assert/strict";
import { pageGroups, pages, pageFor, embeddedSections, settingsFooterVisible, leavingNeedsConfirm } from "./vmac-pages.mjs";

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
test("each old settings section that applies to VMac is embedded in exactly one page", () => {
  const sections = ids.flatMap(id => embeddedSections(id));
  // "keyboard" holds workbench-only options and is not shown in VMac.
  assert.deepEqual([...sections].sort(), ["about", "account", "appearance", "archived-sessions", "mobile", "network", "project", "region", "vault"]);
  assert.deepEqual(embeddedSections("overview"), []);
});

const quiet = { changed: false, proxyDirty: false, saving: false };
test("the settings overlay keeps its footer rules", () => {
  assert.equal(settingsFooterVisible({ embedded: false, section: "network", ...quiet }), true);
  assert.equal(settingsFooterVisible({ embedded: false, section: "about", ...quiet }), false);
  assert.equal(settingsFooterVisible({ embedded: false, section: "about", ...quiet, changed: true }), true);
});
test("an embedded section shows its footer only when there is something to save", () => {
  assert.equal(settingsFooterVisible({ embedded: true, section: "network", ...quiet }), false);
  assert.equal(settingsFooterVisible({ embedded: true, section: "network", ...quiet, changed: true }), true);
  assert.equal(settingsFooterVisible({ embedded: true, section: "network", ...quiet, proxyDirty: true }), true);
  assert.equal(settingsFooterVisible({ embedded: true, section: "region", ...quiet, saving: true }), true);
});
test("leaving a page asks first when anything is unsaved", () => {
  const clean = { changed: false, accountDirty: false, proxyDirty: false, resourceDirty: false };
  assert.equal(leavingNeedsConfirm(clean), false);
  for (const key of Object.keys(clean)) assert.equal(leavingNeedsConfirm({ ...clean, [key]: true }), true, key);
});
