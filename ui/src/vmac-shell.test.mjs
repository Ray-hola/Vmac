import test from "node:test";
import assert from "node:assert/strict";
import { autoStartEnabled, bootView, opensDesktop, setAutoStart, shellStatus, shouldAutoStart, statusDetail } from "./vmac-shell.mjs";

const now = Date.parse("2026-11-20T12:00:00Z");
const later = "2026-11-20T12:10:00Z";
const running = { vm_running: true, ready: true };
const gate = mode => ({ ...running, safety: { gate: { mode, until: later } } });
const status = (value, options) => shellStatus(value, { now, ...options });

test("no status yet reads as loading", () => {
  assert.deepEqual(status(null), { tone: "idle", detail: "正在读取" });
});
test("a running job names what it is doing", () => {
  assert.deepEqual(status({ job: { running: true, kind: "start" } }), { tone: "busy", detail: "正在启动" });
  assert.deepEqual(status({ job: { running: true, kind: "restart" } }), { tone: "busy", detail: "正在重启" });
  assert.deepEqual(status({ job: { running: true, kind: "stop" } }), { tone: "busy", detail: "正在停止" });
  assert.deepEqual(status({ job: { running: true, kind: "other" } }), { tone: "busy", detail: "处理中" });
});
test("a job comes before the guest state", () => {
  assert.deepEqual(status({ ...running, job: { running: true, kind: "restart" } }), { tone: "busy", detail: "正在重启" });
});
test("a failed job is an error", () => {
  assert.deepEqual(status({ ...running, job: { running: false, error: "boom" } }), { tone: "bad", detail: "操作未完成" });
});
test("pending setup asks for attention", () => {
  assert.deepEqual(status(running, { setup: true }), { tone: "warn", detail: "需要完成设置" });
});
test("a stopped guest is idle", () => {
  assert.deepEqual(status({ vm_running: false }), { tone: "idle", detail: "已停止" });
});
test("a guest that is not ready is connecting", () => {
  assert.deepEqual(status({ vm_running: true, ready: false }), { tone: "busy", detail: "连接中" });
});
test("the network gate decides the rest", () => {
  assert.deepEqual(status(gate("open")), { tone: "ok", detail: "已保护" });
  assert.deepEqual(status(gate("checking")), { tone: "busy", detail: "正在检查网络" });
  assert.deepEqual(status(gate("closed")), { tone: "warn", detail: "外网已关闭" });
  assert.deepEqual(status(running), { tone: "warn", detail: "外网状态待确认" });
});

const stopped = { vm_running: false };
const allowed = { enabled: true, installed: true, setup: false };
test("a stopped, installed guest starts on launch", () => {
  assert.equal(shouldAutoStart(stopped, allowed), true);
});
for (const [name, value, options] of [
  ["the setting is off", stopped, { ...allowed, enabled: false }],
  ["the guest is not installed", stopped, { ...allowed, installed: false }],
  ["setup is still pending", stopped, { ...allowed, setup: true }],
  ["there is no status yet", null, allowed],
  ["the guest is already running", { vm_running: true }, allowed],
  ["another job is running", { vm_running: false, job: { running: true, kind: "stop" } }, allowed],
  ["the last job failed", { vm_running: false, job: { running: false, error: "boom" } }, allowed],
  ["storage needs recovery", { vm_running: false, storage_recovery: { required: true } }, allowed],
]) {
  test(`no automatic start when ${name}`, () => {
    assert.equal(shouldAutoStart(value, options), false);
  });
}

test("the boot view shows while the guest comes up", () => {
  assert.equal(bootView({ job: { running: true, kind: "start" } }), true);
  assert.equal(bootView({ vm_running: true, job: { running: true, kind: "restart" } }), true);
  assert.equal(bootView({ vm_running: true, ready: false }), true);
});
test("the boot view stays away from everything else", () => {
  assert.equal(bootView(null), false);
  assert.equal(bootView({ vm_running: false }), false);
  assert.equal(bootView({ vm_running: true, ready: true }), false);
  assert.equal(bootView({ vm_running: true, job: { running: true, kind: "stop" } }), false);
  assert.equal(bootView({ vm_running: false, job: { running: true, kind: "storage" } }), false);
  assert.equal(bootView({ vm_running: true, ready: false, job: { running: false, error: "boom" } }), false);
});

test("only the desktop destination of a ready guest opens the desktop", () => {
  assert.equal(opensDesktop("desktop", { ready: true, setup: false }), true);
  assert.equal(opensDesktop("desktop", { ready: false, setup: false }), false);
  assert.equal(opensDesktop("desktop", { ready: true, setup: true }), false);
  assert.equal(opensDesktop("overview", { ready: true, setup: false }), false);
  assert.equal(opensDesktop("proxy", { ready: true, setup: false }), false);
});

function fakeStorage(initial = {}) {
  const data = { ...initial };
  return { data, getItem: key => (key in data ? data[key] : null), setItem: (key, value) => { data[key] = String(value); }, removeItem: key => { delete data[key]; } };
}
test("starting the guest on launch is on until it is turned off", () => {
  const storage = fakeStorage();
  assert.equal(autoStartEnabled(storage), true);
  setAutoStart(storage, false);
  assert.equal(storage.data["vmac.autoStartGuest"], "0");
  assert.equal(autoStartEnabled(storage), false);
  setAutoStart(storage, true);
  assert.equal("vmac.autoStartGuest" in storage.data, false);
  assert.equal(autoStartEnabled(storage), true);
});
test("unreadable storage keeps the default", () => {
  const broken = { getItem() { throw new Error("denied"); }, setItem() { throw new Error("denied"); }, removeItem() { throw new Error("denied"); } };
  assert.equal(autoStartEnabled(broken), true);
  assert.doesNotThrow(() => setAutoStart(broken, false));
});

test("the status popover names the network gate, the exit and the disk", () => {
  const value = { ...gate("open"), location: { ip: "203.0.113.7", country: "日本", city: "东京" } };
  assert.deepEqual(statusDetail(value, { bytes: 64 * 2 ** 30 }, now),
    { network: "外网已放行", exit: "203.0.113.7 · 日本 · 东京", disk: "64 GiB" });
});
test("the popover says so when there is no exit information", () => {
  assert.equal(statusDetail(gate("closed"), { bytes: 2 ** 30 }, now).exit, "尚未取得出口信息");
  assert.equal(statusDetail({ ...gate("open"), location: { ip: "203.0.113.7" } }, null, now).exit, "203.0.113.7");
  assert.deepEqual(statusDetail(null, null, now), { network: "环境已停止", exit: "尚未取得出口信息", disk: "—" });
});
test("an unknown disk size is a dash", () => {
  assert.equal(statusDetail(gate("open"), null, now).disk, "—");
  assert.equal(statusDetail(gate("open"), { bytes: 96.5 * 2 ** 30 }, now).disk, "96.5 GiB");
});
