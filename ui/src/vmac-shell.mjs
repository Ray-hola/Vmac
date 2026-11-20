import { networkState } from "./safety-state.mjs";

const jobText = { start: "正在启动", restart: "正在重启", stop: "正在停止" };
const networkText = {
  open: ["ok", "已保护"],
  checking: ["busy", "正在检查网络"],
  closed: ["warn", "外网已关闭"],
};

// What the toolbar's status pill says about the guest. The first rule that
// applies wins: work in progress, then a failure, then the guest's own state,
// then its network gate.
export function shellStatus(status, { setup = false, now = Date.now() } = {}) {
  if (!status) return { tone: "idle", detail: "正在读取" };
  if (status.job?.running) return { tone: "busy", detail: jobText[status.job.kind] || "处理中" };
  if (status.job?.error) return { tone: "bad", detail: "操作未完成" };
  if (setup) return { tone: "warn", detail: "需要完成设置" };
  if (!status.vm_running) return { tone: "idle", detail: "已停止" };
  if (!status.ready) return { tone: "busy", detail: "连接中" };
  const [tone, detail] = networkText[networkState(status, now).mode] || ["warn", "外网状态待确认"];
  return { tone, detail };
}

// Whether opening VMac should start the guest by itself. Only a guest that is
// installed, stopped and in no need of attention is started, once per launch.
export function shouldAutoStart(status, { enabled, attempted, installed, setup }) {
  return Boolean(enabled && !attempted && installed && !setup && status && !status.vm_running &&
    !status.job?.running && !status.job?.error && !status.storage_recovery?.required);
}

// Whether the overview gives way to the boot view: only while a start or
// restart runs, or while a guest that is up is still connecting. A failed job
// or any other work keeps the normal overview with its buttons.
export function bootView(status) {
  if (!status) return false;
  const job = status.job || {};
  if (job.running) return job.kind === "start" || job.kind === "restart";
  return Boolean(status.vm_running && !status.ready && !job.error);
}
