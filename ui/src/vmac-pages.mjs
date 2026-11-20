// VMac's pages: one list for the sidebar order, the page headers and the way
// every older entry point maps onto them. The native sidebar holds a copy
// (desktop/GuestSidebar.swift); vmac-pages-sync.test.mjs keeps them in step.
export const pageGroups = [
  { label: "", pages: ["overview"] },
  { label: "这台客机", pages: ["machines", "system", "sharing"] },
  { label: "网络", pages: ["proxy", "checks"] },
  { label: "VMac", pages: ["general", "security", "recovery", "about"] },
];

export const pages = {
  overview: { title: "概览", symbol: "rectangle.grid.2x2", subtitle: "" },
  machines: { title: "虚拟机与磁盘", symbol: "internaldrive", subtitle: "切换和新建虚拟机，调整磁盘容量，清理空间。" },
  system: { title: "账户与系统", symbol: "person.crop.circle", subtitle: "客机的登录账户、时区与语言、输入法。" },
  sharing: { title: "共享与传输", symbol: "arrow.left.arrow.right", subtitle: "Mac 和客机之间怎样共享剪贴板和文件。" },
  proxy: { title: "代理线路", symbol: "network", subtitle: "选择出口节点、管理订阅，所有客机共用这套代理。" },
  checks: { title: "环境检测", symbol: "checkmark.shield", subtitle: "核对隔离报告、网关保护和 Claude 站点连通。" },
  general: { title: "通用", symbol: "gearshape", subtitle: "启动方式和显示。" },
  security: { title: "账户与安全", symbol: "lock.shield", subtitle: "VMac 账户、密码保险箱和远程连接。" },
  recovery: { title: "环境与恢复", symbol: "arrow.counterclockwise", subtitle: "环境存储、组件版本、客机权限和资源。" },
  about: { title: "关于", symbol: "info.circle", subtitle: "" },
};

// Names used before the pages were merged: the old sidebar entries and the
// sections of the old settings panel.
const aliases = {
  lifecycle: "overview", desktop: "overview",
  space: "machines", profiles: "machines", management: "machines",
  login: "system", timezone: "system", input: "system", region: "system",
  network: "proxy",
  settings: "general", keyboard: "general", appearance: "general",
  account: "security", vault: "security", mobile: "security",
  project: "recovery", "archived-sessions": "recovery",
};

export function pageFor(destination) {
  if (Object.hasOwn(pages, destination)) return destination;
  return aliases[destination] || "overview";
}

// The sections of the old settings panel that a page shows in place. The
// general page draws the display settings itself, so "appearance" is not here.
const embedded = {
  system: ["region"],
  proxy: ["network"],
  general: ["keyboard"],
  security: ["account", "vault", "mobile"],
  recovery: ["project", "archived-sessions"],
  about: ["about"],
};

export function embeddedSections(page) {
  return embedded[page] || [];
}

// Old section names whose form sits below other content on its page; a jump
// to one of them scrolls to this element id.
const anchors = { network: "vmac-network", region: "vmac-region" };

export function anchorFor(destination) {
  return anchors[destination] || null;
}

// Every embedded form posts the whole settings object, so the shell's copy
// has to be current: it is read again before a page shows a form, and when a
// job ends. A save that restarts the guest, a start that binds the exit or a
// restore all change settings with no form on screen to notice.
export function settingsNeedReload({ entering, leaving, jobWasRunning, jobRunning }) {
  if (jobWasRunning && !jobRunning) return true;
  return entering !== leaving && embeddedSections(entering).length > 0;
}

// Fresh settings replace the forms on screen only when something changed, so
// a routine re-read does not discard what is being typed.
export function settingsDiffer(previous, next) {
  return JSON.stringify(previous) !== JSON.stringify(next);
}

// What leaving a page has to ask about first, in order: edits in a settings
// form, then a proxy change that is not applied yet.
export function leavePrompts({ from, to, settingsDirty, proxyDirty }) {
  const prompts = [];
  if (settingsDirty && to !== from) prompts.push("settings");
  if (proxyDirty && to !== "proxy") prompts.push("proxy");
  return prompts;
}

// Sections of the settings overlay that save by themselves and show the
// footer only once something has changed.
const selfSaving = ["appearance", "browser", "account", "vault", "mobile", "archived-sessions", "project", "about"];

// Whether the save bar shows. Inside a page it stays away until there is
// something to save; the overlay keeps its own rules.
export function settingsFooterVisible({ embedded, section, changed, proxyDirty, saving }) {
  if (embedded) return Boolean(changed || proxyDirty || saving);
  return !selfSaving.includes(section) || Boolean(changed);
}

// Whether leaving the page would drop edits the user has not saved.
export function leavingNeedsConfirm({ changed, accountDirty, proxyDirty, resourceDirty }) {
  return Boolean(changed || accountDirty || proxyDirty || resourceDirty);
}
