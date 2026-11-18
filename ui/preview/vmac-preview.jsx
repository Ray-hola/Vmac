// Dev-only preview of the VMac workbench with a mocked backend and native bridge.
import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import "../src/style.css";
import "./preview.css";

const query = new URLSearchParams(location.search);
const scenario = query.get("state") || "ready";
window.cageNativeVMWorkbench = true;
window.vmacBuild = "32";

const now = Date.now();
const iso = offset => new Date(now + offset).toISOString();
const state = {
  running: scenario !== "stopped",
  ready: scenario === "ready",
  job: scenario === "starting" ? { id: "j1", kind: "start", running: true, message: "正在连接 macOS 客机并检查网络…" } : { id: "j0", running: false },
};
function status() {
  return {
    vm_running: state.running,
    ready: state.ready,
    guest_system: "macos",
    job: state.job,
    location: { ip: "203.0.113.24", country: "日本", city: "东京" },
    safety: {
      gate: state.ready ? { mode: "open", until: iso(600000), epoch: 4, run_id: "r1", reason: "" }
        : state.running ? { mode: "checking", until: iso(60000), epoch: 4, run_id: "r1", reason: "正在检查出口与隔离" } : null,
      report: {
        created_at: iso(-300000),
        checks: [
          { id: "egress", title: "出站规则", critical: true, state: "passed", evidence: "仅允许经代理核心的 IPv4 TCP/UDP。" },
          { id: "failclose", title: "代理故障关闭", critical: true, state: "passed", evidence: "核心中断后外网立即关闭。" },
          { id: "dns", title: "DNS", critical: true, state: "passed", evidence: "系统 DNS 经当前出口解析。" },
          { id: "share", title: "共享目录", critical: true, state: "passed", evidence: "仅共享默认工作区。" },
          { id: "browser", title: "浏览器配置", critical: true, state: scenario === "ready" ? "passed" : "unknown", evidence: "时区与语言与出口一致。" },
          { id: "ipv6", title: "IPv6", critical: false, state: "passed", evidence: "客机公网 IPv6 已阻断。" },
        ],
      },
    },
  };
}
const nodes = [
  { id: "n1", name: "东京 · 住宅 01", type: "socks5" },
  { id: "n2", name: "东京 · 机房 02", type: "vmess" },
  { id: "n3", name: "大阪 · 住宅 03", type: "trojan" },
  { id: "n4", name: "香港 · 中转 01", type: "ss" },
  { id: "n5", name: "新加坡 · 中转 02", type: "ss" },
];
const proxy = {
  active: true, running: true, network_open: state.ready, state_label: state.ready ? "外网已放行" : "等待检测", port: 17896,
  core_available: true, version: "Mihomo 1.19.13", selected: "n1", route: ["n4", "n1"],
  sources: [
    { id: "s1", name: "日常订阅", remote: true, host: "sub.example.com", interval_hours: 24, updated_at: iso(-3600000), usage: "upload=1073741824;download=2147483648;total=107374182400;expire=1798761600", nodes: nodes.slice(0, 3) },
    { id: "s2", name: "中转节点", remote: false, interval_hours: 0, updated_at: iso(-86400000), nodes: nodes.slice(3) },
  ],
};
let traffic = 0;
const routes = {
  "GET /status": status,
  "GET /settings": () => ({ keyboard: {}, exit_policy: {}, dns_url: "https://1.1.1.1/dns-query" }),
  "GET /proxy": () => proxy,
  "GET /proxy/traffic": () => ({ available: true, upload_rate: 20000 + (traffic++ % 5) * 9000, download_rate: 380000 + (traffic % 7) * 52000, upload_24h: 1.2e8, download_24h: 2.4e9, quota: { used: 2.88e9, total: 1.07e11, remaining: 1.04e11, used_percent: 2.7, updated_at: iso(-3600000) } }),
  "GET /proxy/vmac-protection": () => state.ready ? { state: "protected", reason: "门禁已放行；出口、核心与失效保护证据有效。", run_id: "r1", epoch: 4, until: iso(600000), lease: "L1", report_at: iso(-300000), checks: [
    { label: "客机门禁", state: "passed", detail: "门禁 open · 第 4 代" }, { label: "Mihomo 核心", state: "passed", detail: "监听 127.0.0.1:17896" },
    { label: "出口", state: "passed", detail: "203.0.113.24 · 日本 东京" }, { label: "失效保护", state: "passed", detail: "核心中断时关闭外网" } ] } : { state: state.running ? "checking" : "unready", reason: state.running ? "正在等待客机门禁放行。" : "客机未运行。", checks: [] },
  "GET /proxy/vmac-targets": () => [["cn", "百度"], ["cn", "哔哩哔哩"], ["jp", "Yahoo Japan"], ["jp", "NHK"], ["us", "GitHub"], ["us", "Anthropic"], ["gl", "Cloudflare"], ["gl", "Google"]].map(([group, name], i) => ({ id: "t" + i, group, name })),
  "POST /proxy/vmac-check": () => ({ observed_at: iso(0), tcp: true, udp: false, protection: { lease: "L1" } }),
  "POST /proxy/vmac-probe": body => body.key.startsWith("t") ? { ok: true, ms: 120 + Math.round(Math.random() * 200), status: 200 } : body.key.startsWith("claude") ? { ip: "203.0.113.24", loc: "JP", colo: "NRT", ms: 142 } : body.key === "browser-signals" ? { rows: [["系统时区", 30], ["浏览器语言", 24], ["可用中文字体", 20], ["Intl 区域设置", 10], ["时区偏移", 8], ["渲染家族", 8]].map(([title, weight]) => ({ title, weight, points: Math.round(weight * 0.2), value: "Asia/Tokyo" })), webrtc: false } : { dns: [{ ip: "198.51.100." + (body.key.length % 9), source: body.key, geo: "Tokyo", org: "Example DNS", cc: "JP" }] },
  "GET /proxy/connections": () => ({ uploadTotal: 1.2e7, downloadTotal: 3.4e8, connections: [{ id: "c1", host: "claude.ai", port: 443, network: "tcp", upload: 32000, download: 920000 }, { id: "c2", host: "api.anthropic.com", port: 443, network: "tcp", upload: 12000, download: 220000 }] }),
  "GET /proxy/logs": () => ({ lines: ["核心已启动 · Mihomo 1.19.13", "已载入 5 个节点", "当前链路：香港 · 中转 01 → 东京 · 住宅 01"] }),
  "GET /macos/disk": () => ({ bytes: 64 * 2 ** 30, expandable: true }),
  "POST /macos/space/scan": () => new Promise(resolve => setTimeout(() => resolve({ id: "p1", created_at: iso(0), capacity: 64 * 2 ** 30, available: 21 * 2 ** 30, engine: "Mole 1.60.0", warnings: [], items: [
    { id: "i1", name: "com.apple.Safari", category: "应用缓存", path: "~/Library/Caches/com.apple.Safari", bytes: 31457280 },
    { id: "i2", name: "Google Chrome", category: "应用缓存", path: "~/Library/Caches/Google/Chrome", bytes: 18874368 },
    { id: "i3", name: "Claude", category: "日志", path: "~/Library/Logs/Claude", bytes: 5242880 },
    { id: "i4", name: "CloudKit", category: "应用缓存", path: "~/Library/Caches/CloudKit", bytes: 0, blocked: "受 Mole 保护，保留" },
  ] }), 900)),
  "POST /macos/space/clean": body => body.ids.map(id => ({ id, name: id, trashed: true })),
  "POST /start": () => { state.job = { id: "j2", kind: "start", running: true, message: "正在启动客机…" }; setTimeout(() => { state.running = true; state.ready = true; state.job = { id: "j2", running: false }; }, 4000); return { id: "j2" }; },
  "POST /stop": () => { state.job = { id: "j3", kind: "stop", running: true, message: "正在停止客机…" }; setTimeout(() => { state.running = false; state.ready = false; state.job = { id: "j3", running: false }; }, 2500); return { id: "j3" }; },
  "POST /macos/restart": () => { state.job = { id: "j4", kind: "restart", running: true, message: "正在重启客机…" }; state.ready = false; setTimeout(() => { state.ready = true; state.job = { id: "j4", running: false }; }, 4000); return { id: "j4" }; },
  "GET /environment/initialization": () => ({ required: false }),
};
const realFetch = window.fetch.bind(window);
window.fetch = async (input, options = {}) => {
  const url = new URL(typeof input === "string" ? input : input.url, location.origin);
  if (!url.pathname.startsWith("/api/")) return realFetch(input, options);
  const path = url.pathname.slice(4);
  const method = options.method || "GET";
  const body = options.body ? JSON.parse(options.body) : undefined;
  let handler = routes[`${method} ${path}`];
  if (!handler && path.startsWith("/agent/jobs/")) handler = () => ({ ...state.job, running: false });
  const value = handler ? await handler(body) : {};
  await new Promise(resolve => setTimeout(resolve, 120));
  return new Response(JSON.stringify(value), { status: 200, headers: { "Content-Type": "application/json" } });
};
const profiles = { active: "default", items: [{ id: "default", name: "原有 macOS 客机", installed: true }, { id: "00af2908", name: "测试客机", installed: false }] };
window.cageNativeBridge = {
  async postMessage(message) {
    window.dispatchEvent(new CustomEvent("preview-native", { detail: message }));
    if (message.action === "vmacProfiles") return profiles;
    if (message.action === "showGuestDesktop") return true;
    return true;
  },
};

const { NativeGuestHome } = await import("../src/native-guest-home.jsx");
const { PreviewSidebar } = await import("./preview-sidebar.jsx");

function Preview() {
  const [desktop, setDesktop] = useState(false);
  useEffect(() => {
    const listen = event => {
      if (event.detail.action === "showGuestDesktop") setDesktop(true);
      if (event.detail.action === "showGuestControls") setDesktop(false);
    };
    window.addEventListener("preview-native", listen);
    return () => window.removeEventListener("preview-native", listen);
  }, []);
  const navigate = id => {
    setDesktop(false);
    window.dispatchEvent(new CustomEvent("cage-guest-navigate", { detail: id }));
  };
  return <div className="preview-window">
    <PreviewSidebar onNavigate={navigate} />
    <div className="preview-content">
      <NativeGuestHome />
      {desktop && <div className="preview-desktop" onClick={() => setDesktop(false)}>macOS 客机桌面（原生画面）· 点击返回</div>}
    </div>
  </div>;
}
createRoot(document.getElementById("root")).render(<Preview />);
const initial = query.get("page");
if (initial) setTimeout(() => window.dispatchEvent(new CustomEvent("cage-guest-navigate", { detail: initial })), 600);
