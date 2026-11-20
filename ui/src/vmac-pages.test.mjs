import test from "node:test";
import assert from "node:assert/strict";
import { pageGroups, pages, pageFor, embeddedSections, settingsFooterVisible, leavingNeedsConfirm, settingsNeedReload, settingsDiffer, leavePrompts, anchorFor } from "./vmac-pages.mjs";

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
test("every old settings section is embedded in exactly one page", () => {
  const sections = ids.flatMap(id => embeddedSections(id));
  // "appearance" is the exception: the general page draws those settings itself.
  assert.deepEqual([...sections].sort(), ["about", "account", "archived-sessions", "keyboard", "mobile", "network", "project", "region", "vault"]);
  assert.deepEqual(embeddedSections("general"), ["keyboard"]);
  assert.equal(pageFor("appearance"), "general");
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

const still = { entering: "overview", leaving: "overview", jobWasRunning: false, jobRunning: false };
test("settings are read again before a page shows a form", () => {
  for (const id of ids) {
    const forms = embeddedSections(id).length > 0;
    assert.equal(settingsNeedReload({ ...still, entering: id, leaving: id === "overview" ? "checks" : "overview" }), forms, id);
  }
  assert.equal(settingsNeedReload({ ...still, entering: "system", leaving: "system" }), false, "staying on a page keeps what is being typed");
});
test("settings are read again when a job ends, wherever the user is", () => {
  // A save that restarts the guest, a start that binds the exit, a restore:
  // each changes settings with no form on screen to notice.
  assert.equal(settingsNeedReload({ ...still, jobWasRunning: true, jobRunning: false }), true);
  assert.equal(settingsNeedReload({ ...still, jobWasRunning: true, jobRunning: true }), false);
  assert.equal(settingsNeedReload({ ...still, jobWasRunning: false, jobRunning: true }), false);
  assert.equal(settingsNeedReload(still), false);
});
test("fresh settings replace the forms only when something changed", () => {
  const saved = { timezone: "Asia/Tokyo", exit_policy: { mode: "dynamic" }, mobile_relay: "" };
  assert.equal(settingsDiffer(saved, structuredClone(saved)), false);
  assert.equal(settingsDiffer(saved, { ...saved, timezone: "Europe/Paris" }), true);
  assert.equal(settingsDiffer(saved, { ...saved, exit_policy: { mode: "fixed" } }), true);
  assert.equal(settingsDiffer(null, saved), true);
});
test("leaving a page asks about each kind of unsaved work", () => {
  const none = { settingsDirty: false, proxyDirty: false };
  assert.deepEqual(leavePrompts({ from: "system", to: "overview", ...none }), []);
  assert.deepEqual(leavePrompts({ from: "system", to: "overview", ...none, settingsDirty: true }), ["settings"]);
  assert.deepEqual(leavePrompts({ from: "system", to: "system", ...none, settingsDirty: true }), [], "staying put loses nothing");
  assert.deepEqual(leavePrompts({ from: "proxy", to: "checks", ...none, proxyDirty: true }), ["proxy"]);
  assert.deepEqual(leavePrompts({ from: "proxy", to: "proxy", settingsDirty: true, proxyDirty: true }), []);
  assert.deepEqual(leavePrompts({ from: "proxy", to: "overview", settingsDirty: true, proxyDirty: true }), ["settings", "proxy"]);
});
test("an old section that sits below other content has an anchor to scroll to", () => {
  assert.equal(anchorFor("network"), "vmac-network");
  assert.equal(anchorFor("region"), "vmac-region");
  for (const other of ["proxy", "general", "settings", "account", "nonsense", undefined]) assert.equal(anchorFor(other), null, String(other));
});
