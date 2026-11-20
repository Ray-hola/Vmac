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
