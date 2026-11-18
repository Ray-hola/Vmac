import React from "react";
import { ArrowRight, Check, HardDrive, LoaderCircle, Monitor, Network, Play, Power, RotateCw, ShieldCheck, X } from "lucide-react";
import { gib } from "./vmac-ui";

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

function criticalChecks(status) {
  const checks = status.safety?.report?.checks?.filter(check => check.critical) || [];
  return { passed: checks.filter(check => check.state === "passed").length, total: checks.length };
}

export function GuestOverview({ status, network, request, disk, onStart, onRestart, onStop, onOpen, onNavigate }) {
  const phase = guestPhase(status, request);
  const job = status.job || {};
  const states = stepStates(status, network, phase);
  const checks = criticalChecks(status);
  const busyTitle = { start: "正在启动客机", restart: "正在重启客机", stop: "正在停止客机" }[job.kind] || "正在处理客机操作";
  const copy = {
    busy: [busyTitle, job.message || "正在提交操作…"],
    ready: ["macOS 客机已就绪", "应用、文件和登录状态都保存在客机里。打开桌面继续工作。"],
    connecting: ["正在连接客机", "虚拟机已启动，正在等待客机登录并完成网络检查。"],
    failed: ["客机操作未完成", job.error || "请查看错误信息后重试。"],
    stopped: ["macOS 客机已停止", "启动后会连接现有客机并检查网络，就绪后自动打开桌面。"],
  }[phase];
  const tiles = [
    { id: "proxy", icon: Network, label: "网络出口", value: network.label,
      detail: status.location?.ip ? `${status.location.ip} · ${[status.location.country, status.location.city].filter(Boolean).join(" ")}` : "尚未取得出口信息",
      tone: network.mode === "open" ? "ok" : network.mode === "checking" ? "busy" : "idle" },
    { id: "checks", icon: ShieldCheck, label: "环境检测", value: checks.total ? `${checks.passed} / ${checks.total} 关键项通过` : "尚无检测记录",
      detail: status.safety?.report?.created_at ? `检测于 ${new Date(status.safety.report.created_at).toLocaleString("zh-CN", { hour12: false })}` : "查看隔离报告和网络连通",
      tone: checks.total && checks.passed === checks.total ? "ok" : checks.total ? "warn" : "idle" },
    { id: "space", icon: HardDrive, label: "虚拟磁盘", value: disk ? `${gib(disk.bytes)} GiB` : status.guest_system === "macos" ? "正在读取…" : "尚未安装",
      detail: "扩大磁盘、清理缓存或切换客机", tone: "idle" },
  ];
  return <div className="vm-overview">
    <section className={`vm-card vm-hero ${phase}`} aria-live="polite">
      <div className="vm-monitor" aria-hidden="true">
        <div className="vm-monitor-screen">
          {phase === "busy" ? <LoaderCircle size={22} className="spin" /> : phase === "failed" ? <X size={22} /> : phase === "stopped" ? <Power size={20} /> : <Monitor size={22} />}
        </div>
        <div className="vm-monitor-stand" />
      </div>
      <div className="vm-hero-body">
        <h2>{copy[0]}</h2>
        <p role="status">{copy[1]}</p>
        <div className="vm-actions">
          {(phase === "stopped" || phase === "failed") && <button className="primary large" onClick={onStart}><Play size={15} fill="currentColor" />{phase === "failed" ? "重新启动" : "启动客机"}</button>}
          {phase === "busy" && <button className="primary large" disabled><LoaderCircle size={15} className="spin" />{busyTitle}…</button>}
          {(phase === "ready" || phase === "connecting") && <button className={phase === "ready" ? "primary large" : "large"} onClick={onOpen} disabled={request}><Monitor size={15} />打开客机桌面</button>}
          {status.vm_running && phase !== "busy" && <button className="large" onClick={onRestart}><RotateCw size={15} />重启</button>}
          {status.vm_running && phase !== "busy" && <button className="vm-quiet large" onClick={onStop}><Power size={15} />停止</button>}
        </div>
      </div>
      <ol className="vm-steps" aria-label="启动进度">
        {steps.map(([id, label], index) => <li key={id} className={states[id]}>
          <span className="vm-step-dot">{states[id] === "done" ? <Check size={12} strokeWidth={3} /> : states[id] === "failed" ? <X size={12} strokeWidth={3} /> : states[id] === "active" ? <span className="vm-step-pulse" /> : index + 1}</span>
          <span className="vm-step-label">{label}</span>
        </li>)}
      </ol>
    </section>
    <div className="vm-tiles">
      {tiles.map(({ id, icon: Icon, label, value, detail, tone }) => <button key={id} className={`vm-card vm-tile ${tone}`} onClick={() => onNavigate(id)}>
        <span className="vm-tile-icon"><Icon size={17} /></span>
        <span className="vm-tile-text"><small>{label}</small><strong>{value}</strong><span>{detail}</span></span>
        <ArrowRight size={15} className="vm-tile-arrow" />
      </button>)}
    </div>
  </div>;
}
