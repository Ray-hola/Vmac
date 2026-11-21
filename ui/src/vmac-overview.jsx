import React from "react";
import { LoaderCircle } from "lucide-react";
import { isolationSummary } from "./safety-state.mjs";
import { logo } from "./brand-logo";
import { Group, LinkRow, State, gib } from "./vmac-ui";
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

// The word and dot for the guest's state, shown under its name.
export function guestState(status, request) {
  const phase = guestPhase(status, request);
  const busy = { start: "正在启动", restart: "正在重启", stop: "正在停止" }[status?.job?.kind] || "处理中";
  return { busy: ["busy", busy], ready: ["ok", "已就绪"], connecting: ["busy", "连接中"], failed: ["bad", "操作未完成"], stopped: ["idle", "已停止"] }[phase];
}

export function GuestOverview({ name, status, network, request, disk, onStart, onRestart, onStop, onOpen, onNavigate }) {
  const phase = guestPhase(status, request);
  const job = status.job || {};
  const states = stepStates(status, network, phase);
  const checks = isolationSummary(status);
  const busyTitle = { start: "正在启动客机", restart: "正在重启客机", stop: "正在停止客机" }[job.kind] || "正在处理客机操作";
  const sentence = {
    busy: job.message || "正在提交操作…",
    ready: "应用、文件和登录状态都保存在客机里，打开桌面就能继续。",
    connecting: "虚拟机已启动，正在等待客机登录并完成网络检查。",
    failed: job.error || "请查看错误信息后重试。",
    stopped: "启动后会连接客机并检查网络，就绪后自动打开桌面。",
  }[phase];
  const exit = status.location?.ip ? [status.location.ip, status.location.country, status.location.city].filter(Boolean).join(" · ") : "";
  const checked = status.safety?.report?.created_at ? new Date(status.safety.report.created_at).toLocaleString("zh-CN", { hour12: false }) : "";
  const facts = [
    { id: "proxy", name: "网络出口", value: network.label,
      detail: exit ? `${network.mode === "open" ? "" : "上次检测 · "}${exit}` : "尚未取得出口信息" },
    { id: "checks", name: "环境检测",
      value: checks.total ? `${checks.current ? "" : "上次 · "}${checks.passed} / ${checks.total} 关键项通过` : "尚无检测记录",
      detail: checked ? `检测于 ${checked}` : "查看隔离报告和网络连通" },
    { id: "space", name: "虚拟磁盘", value: disk ? `${gib(disk.bytes)} GiB` : status.guest_system === "macos" ? "正在读取…" : "尚未安装",
      detail: "扩大磁盘、清理缓存或切换客机" },
  ];
  const [tone, word] = guestState(status, request);
  const booting = bootView(status);
  // The guest in the middle of the page: its mark, its name, how it is, and
  // the one thing to do next. While it comes up there is nothing to manage,
  // so only the progress shows beneath.
  return <div className="vm-overview">
    <section className={`vm-hero ${phase}`} aria-live="polite">
      <img className="vm-hero-mark" src={logo} alt="" />
      <h1>{name}</h1>
      <State tone={tone}>{word}</State>
      <p role="status">{sentence}</p>
      {booting ? <>
        <ol className="vm-steps" aria-label="启动进度">
          {steps.map(([id, label], index) => <li key={id} className={states[id]}>
            <span className="vm-step-dot">{index + 1}</span>
            <span className="vm-step-label">{label}</span>
          </li>)}
        </ol>
        {/* A guest that never finishes connecting must still be reachable. */}
        {phase === "connecting" && <div className="vm-actions">
          <button onClick={onOpen} disabled={request}>打开客机桌面</button>
          <button onClick={onRestart}>重启</button>
          <button className="vm-quiet" onClick={onStop}>停止</button>
        </div>}
      </> : <div className="vm-actions">
        {(phase === "stopped" || phase === "failed") && <button className="primary large" onClick={onStart}>{phase === "failed" ? "重新启动" : "启动客机"}</button>}
        {phase === "busy" && <button className="primary large" disabled><LoaderCircle size={15} className="spin" />{busyTitle}…</button>}
        {(phase === "ready" || phase === "connecting") && <button className={phase === "ready" ? "primary large" : "large"} onClick={onOpen} disabled={request}>打开客机桌面</button>}
        {status.vm_running && phase !== "busy" && <button className="large" onClick={onRestart}>重启</button>}
        {status.vm_running && phase !== "busy" && <button className="large" onClick={onStop}>停止</button>}
      </div>}
    </section>
    {!booting && <Group label="客机现状">
      {facts.map(({ id, name: title, value, detail }) => <LinkRow key={id} title={title} detail={detail} value={value} onClick={() => onNavigate(id)} />)}
    </Group>}
  </div>;
}
