import React, { useEffect, useRef, useState } from "react";

import { api, native } from "./api";
import { useAccount } from "./account";
import { requestMacOSRecovery } from "./macos-recovery";
import { Modal } from "./modal";
import { networkState } from "./safety-state.mjs";
import { SettingsPanel } from "./settings";
import { ProxySettings } from "./proxy-settings";
import { SpaceManagement } from "./space-management";
import { DiskCapacity, GuestInputSources, GuestLoginDetails, GuestTimezone, VMProfiles } from "./vmac-management";
import { ChecksPage, protectionText, protectionTone, useVMacProtection } from "./vmac-checks";
import { GuestOverview, guestPhase } from "./vmac-overview";
import { PageHeader, StatusChip } from "./vmac-ui";
import "./native-guest-home.css";

const titles = {
  lifecycle: "客机桌面",
  desktop: "客机桌面",
  space: "存储空间",
  profiles: "虚拟机切换",
  login: "客机账户",
  timezone: "时区",
  input: "输入法",
  proxy: "代理管理",
  checks: "环境检测",
};
const subtitles = {
  space: "调整磁盘容量和清理 macOS 客机。",
  proxy: "选择出口节点、管理订阅，所有客机共用这套代理。",
  checks: "核对隔离报告、网关保护和 Claude 站点连通。",
};
const phaseChip = {
  busy: ["busy", "处理中"], ready: ["ok", "已就绪"], connecting: ["busy", "连接中"], failed: ["bad", "未完成"], stopped: ["idle", "已停止"],
};

export function NativeGuestHome({ setup = null }) {
  const { account } = useAccount();
  useEffect(() => { document.documentElement.classList.add("vmac-theme"); }, []);
  const [status, setStatus] = useState(null);
  const [page, setPage] = useState("lifecycle");
  const [checksTab, setChecksTab] = useState("isolation");
  const [settings, setSettings] = useState(null);
  const [section, setSection] = useState("");
  const [profile, setProfile] = useState("");
  const [disk, setDisk] = useState(null);
  const [scrolled, setScrolled] = useState(false);
  const protection = useVMacProtection(page === "proxy" || page === "checks", status?.safety?.gate);
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
    // Keep the native sidebar selection in step with in-page navigation.
    void publishNavigation(latest.current).catch(() => {});
  }
  async function openSettings(value = "network") {
    try {
      setSettings(await api("/settings"));
      setSection(value);
    } catch (failure) { setError(failure.message); }
  }
  async function openDesktop(destination = "desktop", shouldLaunchClaude = true) {
    if (opened.current) return;
    opened.current = true;
    automatic.current = false;
    setError("");
    setRequest(true);
    try {
      await native("showGuestDesktop", { destination });
      choosePage(destination);
      setSection("");
      if (destination === "desktop" && shouldLaunchClaude && launchClaude.current) {
        launchClaude.current = false;
        void api("/macos/claude/window", { action: "launch" }).catch(() => {});
      }
    } catch (failure) { setError(failure.message); }
    finally { opened.current = false; setRequest(false); }
  }
  async function navigate(destination, checksSection) {
    if (!Object.hasOwn(titles, destination) || opened.current) return;
    if (proxyDirty.current && destination !== "proxy") {
      if (!await confirm({ title: "离开代理管理？", body: "代理更改尚未应用。", confirm: "离开页面" })) {
        await publishNavigation(latest.current);
        return;
      }
      proxyDirty.current = false;
    }
    automatic.current = false;
    setError("");
    if (destination === "checks" && checksSection) setChecksTab(checksSection);
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
      activity: next.job?.running ? next.job.kind || "" : "",
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
  async function stop() {
    if (!latest.current?.vm_running || request || latest.current.job?.running) return;
    if (!await confirm({ title: "停止 macOS 客机？", body: "请先保存客机中的工作。停止后客机文件和登录资料会保留，可随时再次启动。", confirm: "停止客机" })) return;
    setError("");
    setRequest(true);
    automatic.current = false;
    try {
      const accepted = await api("/stop", {});
      setStatus(current => current && { ...current, job: { ...accepted, kind: "stop", running: true, message: "正在停止客机…" } });
      void pollNow.current?.();
    } catch (failure) { setError(failure.message); }
    finally { setRequest(false); }
  }
  useEffect(() => {
    native("vmacProfiles").then(value => {
      setProfile(value?.items?.find(item => item.id === value.active)?.name || "");
    }).catch(() => {});
  }, []);
  const lifecycle = ["lifecycle", "desktop"].includes(page);
  const installed = status?.guest_system === "macos";
  useEffect(() => {
    if (!lifecycle || !installed || disk) return;
    api("/macos/disk").then(setDisk).catch(() => {});
  }, [lifecycle, installed, Boolean(disk)]);
  const network = status && networkState(status);
  const phase = status ? guestPhase(status, request) : "stopped";
  const issue = error || (!status?.job?.running && (status?.job?.error || (status?.vm_running && status?.environment_update_error)));
  const showSetup = Boolean(setup && lifecycle);
  const pageKey = lifecycle ? "desktop" : page;
  const scroller = useRef(null);
  useEffect(() => { scroller.current?.scrollTo({ top: 0 }); }, [pageKey]);
  const chip = !status ? null
    : lifecycle ? <StatusChip tone={phaseChip[phase][0]}>{phaseChip[phase][1]}</StatusChip>
    : page === "checks" ? <StatusChip tone={protectionTone[protection.state] || "idle"}>{protectionText(protection)}</StatusChip>
    : page === "proxy" ? null
    : <StatusChip tone={phaseChip[phase][0]}>{profile || "macOS 客机"} · {phaseChip[phase][1]}</StatusChip>;
  return <main ref={scroller} className={showSetup ? "native-guest-home native-setup-home" : "native-guest-home"}
    onScroll={event => setScrolled(event.currentTarget.scrollTop > 4)} data-scrolled={scrolled || undefined}>
    {!showSetup && <PageHeader title={titles[page]} aside={chip}
      subtitle={lifecycle ? (profile ? `${profile} · 原生客机画面与运行状态` : "原生客机画面与运行状态") : subtitles[page]} />}
    {setup && <div className="native-setup-content" hidden={!showSetup}>{setup}</div>}
    {!showSetup && issue && <div className="vm-banner" role="alert"><span>{issue}</span><button onClick={() => { setError(""); void pollNow.current?.(); }}>重新检查</button></div>}
    {!showSetup && <div className="vm-page" key={pageKey}>
      {!status ? <div className="vm-skeleton" role="status" aria-label="正在读取客机状态"><span /><span /><span /></div> :
      lifecycle ? <GuestOverview status={status} network={network} request={request} disk={disk}
        onStart={() => lifecycleAction.current?.("start")} onRestart={() => lifecycleAction.current?.("restart")}
        onStop={stop} onOpen={() => openDesktop()} onNavigate={navigate} /> :
      page === "space" ? <>
        {installed ? <DiskCapacity status={status} onConfirm={confirm} onChanged={() => { setDisk(null); void pollNow.current?.(); }} /> : <section className="vm-card vm-empty" aria-label="虚拟磁盘">
          <h2>还没有安装 macOS</h2><p>完成安装后，这里会显示磁盘容量、扩容和缓存清理。</p>
          <button className="primary" onClick={() => navigate("desktop")}>打开安装向导</button>
        </section>}
        {installed && <SpaceManagement ready={status.ready && !status.job?.running} onConfirm={confirm} onStart={() => lifecycleAction.current?.("start")} running={status.vm_running} />}
      </> : page === "profiles" ? <VMProfiles status={status} onConfirm={confirm} />
      : page === "login" ? <GuestLoginDetails installed={installed} username={account?.macos_guest_user} passwordPending={account?.macos_password_pending} />
      : page === "timezone" ? <GuestTimezone status={status} installed={installed} settingsOpen={Boolean(section)}
          onSettings={() => openSettings("region")} onRestart={() => lifecycleAction.current?.("restart")} />
      : page === "input" ? <GuestInputSources ready={status.ready} onOpen={() => openDesktop("desktop", false)} />
      : page === "checks" ? <ChecksPage status={status} protection={protection} tab={checksTab} onTabChange={setChecksTab}
          onConfirm={confirm} onSettings={openSettings} onInstall={setup && !installed ? () => navigate("desktop") : undefined} />
      : <ProxySettings status={status} onConfirm={confirm} onDirty={value => { proxyDirty.current = value; }}
          onApplied={() => pollNow.current?.()} onChecks={() => navigate("checks", "gateway")} protection={protection} />}
    </div>}
    {section && status && settings && <SettingsPanel current={settings} status={status} initialSection={section}
      onClose={() => setSection("")} onConfirm={confirm} onSaved={async () => setSettings(await api("/settings"))} />}
    {dialog && <Modal title={dialog.title} onClose={() => resolve(false)}
      footer={<><button onClick={() => resolve(false)}>取消</button><button className="primary" onClick={() => resolve(true)}>{dialog.confirm}</button></>}>
      <div className="modal-body">{dialog.body}</div>
    </Modal>}
  </main>;
}
