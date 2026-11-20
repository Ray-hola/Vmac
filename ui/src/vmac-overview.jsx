import React from "react";
import { Check, HardDrive, LoaderCircle, Monitor, Network, Play, Power, RotateCw, ShieldCheck, X } from "lucide-react";
import { isolationSummary } from "./safety-state.mjs";
import { Group, LinkRow, State, gib } from "./vmac-ui";
import { logo } from "./brand-logo";
import { bootView } from "./vmac-shell.mjs";

const steps = [["vm", "启动虚拟机"], ["guest", "连接客机"], ["network", "网络检查"], ["desktop", "打开桌面"]];

export function guestPhase(status, request) {
  const job = status?.job || {};
  if (request || job.running) return "busy";
  if (status?.ready) return "ready";
  if (status?.vm_running) return "connecting";
  return job.error ? "failed" : "stopped";
}

function stepStates(status, network, phase) {
  const open = network.mode === "open";
  return {
    vm: status.vm_running ? "done" : phase === "busy" ? "active" : "idle",
    guest: status.ready ? "done" : status.vm_running ? "active" : "idle",
    network: open ? "done" : network.mode === "checking" ? "active" : status.ready && network.mode === "closed" ? "failed" : "idle",
    desktop: status.ready && open ? "next" : "idle",
  };
}

export function GuestOverview({ name, status, network, request, disk, onStart, onRestart, onStop, onOpen, onNavigate }) {
  const phase = guestPhase(status, request);
  const job = status.job || {};
  const states = stepStates(status, network, phase);
  const checks = isolationSummary(status);
  const busyTitle = { start: "正在启动客机", restart: "正在重启客机", stop: "正在停止客机" }[job.kind] || "正在处理客机操作";
  const copy = {
    busy: [busyTitle, job.message || "正在提交操作…"],
    ready: ["macOS 客机已就绪", "应用、文件和登录状态都保存在客机里，打开桌面就能继续。"],
    connecting: ["正在连接客机", "虚拟机已启动，正在等待客机登录并完成网络检查。"],
    failed: ["客机操作未完成", job.error || "请查看错误信息后重试。"],
    stopped: ["macOS 客机已停止", "启动后会连接客机并检查网络，就绪后自动打开桌面。"],
  }[phase];
  // The card's status line: a dot and a word for the guest's state.
  const state = { busy: ["busy", busyTitle], ready: ["ok", "已就绪"], connecting: ["busy", "连接中"], failed: ["bad", "操作未完成"], stopped: ["idle", "已停止"] }[phase];
  const exit = status.location?.ip ? [status.location.ip, status.location.country, status.location.city].filter(Boolean).join(" · ") : "";
  const checked = status.safety?.report?.created_at ? new Date(status.safety.report.created_at).toLocaleString("zh-CN", { hour12: false }) : "";
  const rows = [
    { id: "proxy", icon: Network, title: "网络出口",
      detail: exit ? `${network.mode === "open" ? "" : "上次检测 · "}${exit}` : "尚未取得出口信息",
      tone: network.mode === "open" ? "ok" : network.mode === "checking" ? "busy" : "idle", value: network.label },
    { id: "checks", icon: ShieldCheck, title: "环境检测",
      detail: checked ? `检测于 ${checked}` : "查看隔离报告和网络连通",
      tone: checks.current && checks.passed === checks.total && checks.total ? "ok" : checks.total ? "warn" : "idle",
      value: checks.total ? `${checks.current ? "" : "上次 · "}${checks.passed} / ${checks.total} 关键项通过` : "尚无检测记录" },
    { id: "space", icon: HardDrive, title: "虚拟磁盘", detail: "扩大磁盘、清理缓存或切换客机",
      value: disk ? `${gib(disk.bytes)} GiB` : status.guest_system === "macos" ? "正在读取…" : "尚未安装" },
  ];
  const progress = <ol className="vm-steps" aria-label="启动进度">
    {steps.map(([id, label], index) => <li key={id} className={states[id]}>
      <span className="vm-step-dot">{states[id] === "done" ? <Check size={12} strokeWidth={3} /> : states[id] === "failed" ? <X size={12} strokeWidth={3} /> : states[id] === "active" ? <span className="vm-step-pulse" /> : index + 1}</span>
      <span className="vm-step-label">{label}</span>
    </li>)}
  </ol>;
  // While the guest comes up there is nothing to manage: show only the progress.
  if (bootView(status)) {
    return <section className="vm-boot" aria-live="polite">
      <img className="vm-boot-logo" src={logo} alt="" />
      <h2>{copy[0]}</h2>
      <p role="status">{copy[1]}</p>
      {progress}
      {/* A guest that never finishes connecting must still be reachable. */}
      {phase === "connecting" && <div className="vm-actions vm-boot-actions">
        <button onClick={onOpen} disabled={request}><Monitor size={15} />打开客机桌面</button>
        <button onClick={onRestart}><RotateCw size={15} />重启</button>
        <button className="vm-quiet" onClick={onStop}><Power size={15} />停止</button>
      </div>}
    </section>;
  }
  return <div className="vm-overview">
    <article className={`vm-card vm-hero ${phase}`} aria-live="polite">
      <State tone={state[0]}>{state[1]}</State>
      <h2>{name}</h2>
      <p role="status">{copy[1]}</p>
      <div className="vm-actions">
        {(phase === "stopped" || phase === "failed") && <button className="primary large" onClick={onStart}><Play size={15} fill="currentColor" />{phase === "failed" ? "重新启动" : "启动客机"}</button>}
        {phase === "busy" && <button className="primary large" disabled><LoaderCircle size={15} className="spin" />{busyTitle}…</button>}
        {(phase === "ready" || phase === "connecting") && <button className={phase === "ready" ? "primary large" : "large"} onClick={onOpen} disabled={request}><Monitor size={15} />打开客机桌面</button>}
        {status.vm_running && phase !== "busy" && <button className="large" onClick={onRestart}><RotateCw size={15} />重启</button>}
        {status.vm_running && phase !== "busy" && <button className="vm-quiet large" onClick={onStop}><Power size={15} />停止</button>}
      </div>
    </article>
    <Group label="状态">
      {rows.map(({ id, icon, title, detail, tone, value }) => <LinkRow key={id} icon={icon} title={title} detail={detail} onClick={() => onNavigate(id)}>
        {tone ? <State tone={tone}>{value}</State> : value}
      </LinkRow>)}
    </Group>
  </div>;
}
