import React, { useEffect, useRef, useState } from "react";

import { api, native } from "./api";
import { requestMacOSRecovery } from "./macos-recovery";
import { Modal } from "./modal";
import { SafetyPanel } from "./safety";
import { networkState } from "./safety-state.mjs";
import { SettingsPanel } from "./settings";
import { ProxySettings } from "./proxy-settings";
import { SpaceManagement } from "./space-management";
import { DiskCapacity, VMProfiles } from "./vmac-management";
import { ClaudeChecks, NetworkChecks, SiteChecks, useVMacProtection } from "./vmac-checks";
import "./native-guest-home.css";

const titles = {
  lifecycle: "启动与重启",
  desktop: "客机桌面",
  space: "虚拟机管理",
  proxy: "代理管理",
};

export function NativeGuestHome({ setup = null }) {
  useEffect(() => {
    document.documentElement.classList.add("vmac-theme");
    return () => document.documentElement.classList.remove("vmac-theme");
  }, []);
  const [status, setStatus] = useState(null);
  const [page, setPage] = useState("lifecycle");
  const [vmTab, setVMTab] = useState("space");
  const [settings, setSettings] = useState(null);
  const [section, setSection] = useState("");
  const [safetyOpen, setSafetyOpen] = useState(false);
  const protection = useVMacProtection(page === "proxy" || safetyOpen, status?.safety?.gate);
  const [error, setError] = useState("");
  const [request, setRequest] = useState(false);
  const [dialog, setDialog] = useState(null);
  const setupActive = useRef(Boolean(setup));
  setupActive.current = Boolean(setup);
  const automatic = useRef(true);
  const restartPending = useRef(false);
  const opened = useRef(false);
  const launchClaude = useRef(true);
  const latest = useRef(null);
  const currentPage = useRef("lifecycle");
  const proxyDirty = useRef(false);
  const pollNow = useRef(null);
  const lifecycleAction = useRef(null);

  function confirm(options) {
    return new Promise(resolve => setDialog({ ...options, resolve }));
  }
  function resolve(value) {
    dialog.resolve(value);
    setDialog(null);
  }
  function choosePage(value) {
    currentPage.current = value;
    setPage(value);
  }
  async function openSettings(value = "network") {
    try {
      setSettings(await api("/settings"));
      setSection(value);
    } catch (failure) { setError(failure.message); }
  }
  async function openDesktop(destination = "desktop") {
    if (opened.current) return;
    opened.current = true;
    automatic.current = false;
    setError("");
    setRequest(true);
    try {
      await native("showGuestDesktop", { destination });
      choosePage(destination);
      setSection("");
      if (destination === "desktop" && launchClaude.current) {
        launchClaude.current = false;
        void api("/macos/claude/window", { action: "launch" }).catch(() => {});
      }
    } catch (failure) { setError(failure.message); }
    finally { opened.current = false; setRequest(false); }
  }
  async function navigate(destination) {
    if (!(destination in titles) || opened.current) return;
    if (proxyDirty.current && destination !== "proxy") {
      if (!await confirm({ title: "离开代理管理？", body: "代理更改尚未应用。", confirm: "离开页面" })) {
        await publishNavigation(latest.current);
        return;
      }
      proxyDirty.current = false;
    }
    automatic.current = false;
    setError("");
    choosePage(destination);
    if (destination === "desktop" && !setupActive.current && latest.current?.ready) await openDesktop(destination);
  }
  async function publishNavigation(next) {
    if (!next) return;
    await native("guestNavigationStatus", {
      setup: setupActive.current,
      running: next.vm_running,
      ready: next.ready,
      busy: Boolean(next.job?.running),
      failed: Boolean(!next.job?.running && next.job?.error),
      network: networkState(next).label,
      destination: currentPage.current,
    });
  }
  useEffect(() => {
    let live = true;
    let timer;
    let wasRunning = false;
    let acknowledged = false;
    let lastNavigation = "";
    async function poll() {
      clearTimeout(timer);
      try {
        const next = await api("/status");
        if (!live) return;
        latest.current = next;
        setStatus(next);
        if (!acknowledged) {
          acknowledged = true;
          void native("workbenchReady").catch(() => {});
        }
        if (restartPending.current && (!next.vm_running || (next.job?.kind === "restart" && next.job.running))) restartPending.current = false;
        if (wasRunning && !next.vm_running) {
          choosePage("lifecycle");
          void native("showGuestControls").catch(() => {});
        }
        wasRunning = next.vm_running;
        const key = JSON.stringify([setupActive.current, next.vm_running, next.ready, next.job?.running, next.job?.error, networkState(next).label, currentPage.current]);
        if (key !== lastNavigation) {
          lastNavigation = key;
          void publishNavigation(next).catch(() => {});
        }
        if (!setupActive.current && automatic.current && !restartPending.current && next.vm_running && next.ready && !next.job?.running && !next.job?.error) void openDesktop();
      } catch (failure) {
        if (live) setError(failure.message);
      } finally {
        if (live) timer = setTimeout(poll, 1800);
      }
    }
    function settingsRequested() {
      automatic.current = false;
      void openSettings();
    }
    function restartRequested() {
      restartPending.current = true;
      automatic.current = true;
      choosePage("lifecycle");
      setSection("");
    }
    function navigationRequested(event) {
      if (event.detail === "start" || event.detail === "restart") void lifecycleAction.current?.(event.detail);
      else void navigate(event.detail);
    }
    window.addEventListener("cage-guest-settings", settingsRequested);
    window.addEventListener("cage-guest-restarting", restartRequested);
    window.addEventListener("cage-guest-navigate", navigationRequested);
    pollNow.current = poll;
    poll();
    return () => {
      live = false;
      clearTimeout(timer);
      pollNow.current = null;
      window.removeEventListener("cage-guest-settings", settingsRequested);
      window.removeEventListener("cage-guest-restarting", restartRequested);
      window.removeEventListener("cage-guest-navigate", navigationRequested);
    };
  }, []);

  useEffect(() => {
    let live = true;
    let timer;
    let previous = {};
    async function sample() {
      try {
        const traffic = await api("/proxy/traffic");
        if (!live) return;
        previous = traffic;
        await native("guestTrafficStatus", traffic);
      } catch {
        if (live) await native("guestTrafficStatus", { ...previous, available: false, upload_rate: null, download_rate: null }).catch(() => {});
      } finally {
        if (live) timer = setTimeout(sample, 2000);
      }
    }
    sample();
    return () => { live = false; clearTimeout(timer); };
  }, []);

  useEffect(() => {
    window.cageWorkbenchAction = async action => {
      if (action === "settings") return openSettings();
      if (action !== "quit") return;
      if (!status?.vm_running && !status?.job?.running) return native("quitNow");
      if (!await confirm({ title: "退出 VMac？", body: "请先保存客机中的工作。退出时会停止客机。", confirm: "停止客机并退出" })) return;
      try {
        const accepted = await api("/stop", {});
        while (true) {
          const job = await api("/agent/jobs/" + accepted.id);
          if (job.error) throw new Error(job.error);
          if (!job.running) break;
          await new Promise(resolve => setTimeout(resolve, 700));
        }
        await native("quitNow");
      } catch (failure) { setError(failure.message); }
    };
    return () => { delete window.cageWorkbenchAction; };
  }, [status?.vm_running, status?.job?.running]);

  async function start() {
    setError("");
    setRequest(true);
    automatic.current = true;
    try {
      const accepted = await api("/start", {});
      setStatus(current => current && { ...current, job: { ...accepted, running: true, message: "正在启动客机…" } });
    } catch (failure) { setError(failure.message); }
    finally { setRequest(false); }
  }
  lifecycleAction.current = async action => {
    if (setupActive.current) { choosePage("desktop"); return; }
    if (!latest.current || request || latest.current.job?.running) return;
    setError("");
    if (action === "start") {
      choosePage("lifecycle");
      await start();
      return;
    }
    if (!latest.current.vm_running) return;
    setRequest(true);
    try {
      const accepted = await requestMacOSRecovery("restart", confirm);
      if (!accepted) return;
      choosePage("lifecycle");
      restartPending.current = true;
      automatic.current = true;
      setStatus(current => ({ ...current, job: { ...accepted, running: true } }));
      void pollNow.current?.();
    } catch (failure) { setError(failure.message); }
    finally { setRequest(false); }
  };
  async function openGuestPage(url) {
    try {
      await api("/browser/tabs", { url });
      await openDesktop();
      return true;
    } catch (failure) {
      setError(failure.message);
      return false;
    }
  }
  const busy = request || status?.job?.running;
  const network = status && networkState(status);
  const issue = error || (!status?.job?.running && (status?.job?.error || (status?.vm_running && status?.environment_update_error)));
  const lifecycle = ["lifecycle", "desktop"].includes(page);
  const showSetup = Boolean(setup && lifecycle);
  return <main className={showSetup ? "native-guest-home native-setup-home" : "native-guest-home"}>
    {!showSetup && <header className="native-page-header">
      <div>
        <h1>{titles[page]}</h1>
        <p>{page === "proxy" ? "管理客机的代理节点、出口和连接规则。" :
          page === "space" ? "管理客机磁盘、清理缓存，或切换 macOS 客机。" :
          page === "desktop" ? "在原生客机画面中使用应用。" : "管理当前 macOS 客机的运行状态。"}</p>
      </div>
    </header>}
    {setup && <div className="native-setup-content" hidden={!showSetup}>{setup}</div>}
    {!showSetup && issue && <div className="native-page-error" role="alert">{issue}<button onClick={() => pollNow.current?.()}>重新检查</button></div>}
    {!showSetup && (!status ? <p className="native-page-pending" role="status">正在读取客机状态…</p> :
      lifecycle ? <section className="native-lifecycle">
        <h2>{busy ? "正在处理客机操作" : status.ready ? "macOS 客机已就绪" : status.vm_running ? "正在连接客机" : "macOS 客机已停止"}</h2>
        <p role="status">{busy ? status.job?.message || "正在提交操作…" : status.ready ? "打开桌面即可继续使用客机里的应用和文件。" : "启动后会连接现有客机并检查网络。"}</p>
        <div className="native-primary-actions">
          {status.vm_running && <button className="primary" onClick={() => openDesktop()} disabled={request}>打开客机桌面</button>}
        </div>
        <div className="native-machine-facts">
          <span><strong>运行状态</strong>{status.ready ? "已连接" : status.vm_running ? "启动中" : "已停止"}</span>
          <span><strong>网络检查</strong>{network.label}</span>
        </div>
        <button className="native-text-action" onClick={() => setSafetyOpen(true)}>查看网络与隔离检查</button>
      </section> :
      page === "space" ? <>
        <div className="vmac-subnav" role="group" aria-label="虚拟机管理">
          <button aria-pressed={vmTab === "space"} onClick={() => setVMTab("space")}>空间管理</button>
          <button aria-pressed={vmTab === "profiles"} onClick={() => setVMTab("profiles")}>虚拟机切换</button>
        </div>
        {vmTab === "space" ? <>
          {status.guest_system === "macos" ? <DiskCapacity status={status} onConfirm={confirm} onChanged={() => pollNow.current?.()} /> : <section className="vmac-section" aria-label="虚拟磁盘">
            <h2>虚拟磁盘</h2><p>安装 macOS 后，这里会显示磁盘容量和扩容操作。</p>
            <button onClick={() => navigate("desktop")}>打开安装向导</button>
          </section>}
          <SpaceManagement ready={status.ready && !status.job?.running} onConfirm={confirm} />
        </> : <VMProfiles status={status} onConfirm={confirm} />}
      </> : <>
        <NetworkChecks protection={protection} onEnvironment={() => setSafetyOpen(true)} />
        <ProxySettings status={status} onConfirm={confirm} onDirty={value => { proxyDirty.current = value; }}
          onApplied={() => pollNow.current?.()} />
      </>)}
    {section && status && settings && <SettingsPanel current={settings} status={status} initialSection={section}
      onClose={() => setSection("")} onConfirm={confirm} onSaved={async () => setSettings(await api("/settings"))} />}
    {safetyOpen && status && <SafetyPanel status={status} onClose={() => setSafetyOpen(false)}
      onConfirm={confirm} onSettings={openSettings} onOpenPage={openGuestPage}
      extraChecks={[
        { id: "claude", label: "Claude 检测", panel: <ClaudeChecks protection={protection} /> },
        { id: "network", label: "网络连通测试", panel: <SiteChecks protection={protection} /> },
      ]} />}
    {dialog && <Modal title={dialog.title} onClose={() => resolve(false)}
      footer={<><button onClick={() => resolve(false)}>取消</button><button className="primary" onClick={() => resolve(true)}>{dialog.confirm}</button></>}>
      <div className="modal-body">{dialog.body}</div>
    </Modal>}
  </main>;
}
