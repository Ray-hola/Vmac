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

// Whole gibibytes read as "64"; anything else keeps two decimals.
export const gib = bytes => Number((bytes / 2 ** 30).toFixed(bytes % 2 ** 30 ? 2 : 0));

// What a folder takes on disk, in the unit that fits; nothing for an empty or unknown size.
export function diskSize(bytes) {
  if (!(bytes > 0)) return "";
  if (bytes < 2 ** 20) return "不到 1 MB";
  const [value, unit] = bytes < 2 ** 30 ? [bytes / 2 ** 20, "MB"] : [bytes / 2 ** 30, "GB"];
  return `${Number(value.toFixed(1))} ${unit}`;
}

// What the page asks before a guest is removed. Its folder goes to the Trash,
// and Finder can put it back; a guest that was never opened has no folder.
export function removalNotice(profile) {
  const size = diskSize(profile.size);
  const title = `删除「${profile.name}」？`;
  if (!size) return { title, body: "它还没有安装 macOS，也还没有打开过。删除只是把它从列表中移除。", confirm: "删除", danger: true };
  const what = profile.installed ? `这台客机的磁盘和数据（${size}）会移到废纸篓` : `它还没有安装 macOS，只有少量配置（${size}）会移到废纸篓`;
  return {
    title,
    body: `${what}，并从列表中移除。清空废纸篓之前，在访达的废纸篓里对它选「放回原处」，它会重新出现在这里。`,
    confirm: "移到废纸篓",
    danger: true,
  };
}

// The three lines of the popover behind the status pill: the network gate,
// where traffic leaves, and the size of the guest's disk.
export function statusDetail(status, disk, now = Date.now()) {
  const { ip, country, city } = status?.location || {};
  return {
    network: networkState(status, now).label,
    exit: ip ? [ip, country, city].filter(Boolean).join(" · ") : "尚未取得出口信息",
    disk: disk?.bytes ? `${gib(disk.bytes)} GiB` : "—",
  };
}

// Whether opening VMac should start the guest by itself. Only a guest that is
// installed, stopped and in no need of attention is started; the caller asks
// once, with the first status of a launch.
export function shouldAutoStart(status, { enabled, installed, setup }) {
  return Boolean(enabled && installed && !setup && status && !status.vm_running &&
    !status.job?.running && !status.job?.error && !status.storage_recovery?.required);
}

const autoStartKey = "vmac.autoStartGuest";

// Starting the guest on launch is on unless it was turned off; storage that
// cannot be read or written keeps that default.
export function autoStartEnabled(storage) {
  try { return storage.getItem(autoStartKey) !== "0"; } catch { return true; }
}

export function setAutoStart(storage, enabled) {
  try {
    if (enabled) storage.removeItem(autoStartKey);
    else storage.setItem(autoStartKey, "0");
  } catch { /* storage unavailable: the switch falls back to on */ }
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

// "desktop" is what the sidebar's guest card sends: it shows the guest's
// picture, but only once the guest is ready and no setup is in the way.
export function opensDesktop(destination, { ready, setup }) {
  return destination === "desktop" && Boolean(ready) && !setup;
}
