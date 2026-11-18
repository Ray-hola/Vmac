// HTML stand-in for desktop/GuestSidebar.swift, used only by the dev preview.
import React, { useEffect, useState } from "react";
import { Cpu, Gauge, HardDrive, Monitor, Network, Play, RotateCw, Settings, ShieldCheck } from "lucide-react";

const items = [["desktop", "客机桌面", Monitor], ["space", "虚拟机管理", HardDrive], ["proxy", "代理管理", Network], ["checks", "环境检测", ShieldCheck]];
const speed = v => v == null ? "—" : v >= 1048576 ? `${(v / 1048576).toFixed(1)} MB/s` : v >= 1024 ? `${(v / 1024).toFixed(1)} KB/s` : `${Math.round(v)} B/s`;
const gb = v => `${(v / 1073741824).toFixed(2)} GB`;

export function PreviewSidebar({ onNavigate }) {
  const [width, setWidth] = useState(Number(new URLSearchParams(location.search).get("sidebar")) || 188);
  const [nav, setNav] = useState({ destination: "desktop" });
  const [traffic, setTraffic] = useState({});
  useEffect(() => {
    const listen = event => {
      const { action, ...body } = event.detail;
      if (action === "guestNavigationStatus") setNav(body);
      if (action === "guestTrafficStatus") setTraffic(body);
    };
    window.addEventListener("preview-native", listen);
    return () => window.removeEventListener("preview-native", listen);
  }, []);
  const compact = width < 146;
  const index = Math.max(0, items.findIndex(([id]) => id === (nav.destination === "lifecycle" ? "desktop" : nav.destination)));
  const machine = nav.busy ? "busy" : nav.ready ? "ready" : nav.running ? "running" : "stopped";
  const quota = traffic.quota;
  return <aside className={`pv-sidebar ${compact ? "compact" : ""}`} style={{ width }}>
    <div className="pv-brand"><span className="pv-logo">V</span>{!compact && <strong>VMac_</strong>}</div>
    <div className={`pv-machine ${machine}`} onClick={() => onNavigate("desktop")}>
      {!compact && <div className="pv-machine-text">
        <strong><i className="pv-dot" />{nav.profile || "原有 macOS 客机"}</strong>
        <small>{nav.busy ? "正在处理…" : nav.ready ? "运行中 · 已就绪" : nav.running ? "运行中 · 连接中" : "已停止"}</small>
      </div>}
      <button className="pv-power" disabled={nav.setup || nav.busy} onClick={event => { event.stopPropagation(); onNavigate(nav.running ? "restart" : "start"); }} title={nav.running ? "重启" : "启动"}>
        {nav.busy ? <span className="pv-spin" /> : nav.running ? <RotateCw size={15} /> : <Play size={15} fill="currentColor" />}
      </button>
    </div>
    <nav className="pv-nav">
      <span className="pv-pill" style={{ transform: `translateY(${index * 38}px)` }} />
      {items.map(([id, label, Icon]) => <button key={id} className={index === items.findIndex(([key]) => key === id) ? "selected" : ""} onClick={() => onNavigate(id)} title={label}>
        <Icon size={compact ? 19 : 16} strokeWidth={1.7} />{!compact && <span>{label}</span>}
      </button>)}
    </nav>
    <div className="pv-foot">
      {!compact ? <div className="pv-telemetry">
        <div className="pv-speeds"><span><b className="up">↑</b>{speed(traffic.upload_rate)}</span><span><b className="down">↓</b>{speed(traffic.download_rate)}</span></div>
        <div className="pv-quota"><span>已用 {quota ? gb(quota.used) : "—"}</span><span>余 {quota ? gb(quota.remaining) : "—"}</span></div>
        <div className="pv-bar"><i style={{ width: `${quota ? 100 - quota.used_percent : 0}%` }} /></div>
      </div> : <div className="pv-telemetry"><Gauge size={18} /><small>{quota ? `${Math.round(quota.used_percent)}%` : "—"}</small></div>}
      <div className="pv-lamps">
        {[["proxy", "代理", traffic.available ? (nav.network === "外网已放行" ? "ok" : "warn") : "off"], ["checks", "环境", nav.failed ? "bad" : nav.busy ? "warn" : nav.ready ? "ok" : "off"], ["desktop", "虚拟机", nav.running ? "ok" : "off"]].map(([id, label, tone]) =>
          <button key={id} className={tone} onClick={() => onNavigate(id)} title={label}><i />{!compact && label}</button>)}
      </div>
      <button className="pv-settings" onClick={() => window.dispatchEvent(new Event("cage-guest-settings"))} title="设置"><Settings size={compact ? 19 : 16} strokeWidth={1.7} />{!compact && <span>设置</span>}</button>
    </div>
    <input className="pv-resize" type="range" min="64" max="260" value={width} onChange={event => setWidth(Number(event.target.value))} aria-label="侧栏宽度" />
  </aside>;
}
// Silence unused-import lint in this dev-only file.
void Cpu;
