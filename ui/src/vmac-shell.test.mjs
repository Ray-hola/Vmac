import test from "node:test";
import assert from "node:assert/strict";
import { shellStatus } from "./vmac-shell.mjs";

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
