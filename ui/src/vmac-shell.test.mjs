import test from "node:test";
import assert from "node:assert/strict";
import { bootView, shellStatus, shouldAutoStart } from "./vmac-shell.mjs";

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
const allowed = { enabled: true, attempted: false, installed: true, setup: false };
test("a stopped, installed guest starts on launch", () => {
  assert.equal(shouldAutoStart(stopped, allowed), true);
});
for (const [name, value, options] of [
  ["the setting is off", stopped, { ...allowed, enabled: false }],
  ["it was already tried this launch", stopped, { ...allowed, attempted: true }],
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
