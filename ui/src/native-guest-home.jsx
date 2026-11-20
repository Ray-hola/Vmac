import React, { useEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { CircleAlert } from "lucide-react";

import { api, native } from "./api";
import { useAccount } from "./account";
import { requestMacOSRecovery } from "./macos-recovery";
import { Modal } from "./modal";
import { networkState } from "./safety-state.mjs";
import { autoStartEnabled, opensDesktop, shellStatus, shouldAutoStart, statusDetail } from "./vmac-shell.mjs";
import { anchorFor, embeddedSections, leavePrompts, pageFor, pages, settingsDiffer, settingsNeedReload } from "./vmac-pages.mjs";
import { SettingsPanel } from "./settings";
import { ProxySettings } from "./proxy-settings";
import { GeneralPage } from "./vmac-general";
import { SharingPage } from "./vmac-sharing";
import { SpaceManagement } from "./space-management";
import { DiskCapacity, GuestInputSources, GuestLoginDetails, GuestTimezone, VMProfiles } from "./vmac-management";
import { ChecksPage, useVMacProtection } from "./vmac-checks";
import { GuestOverview } from "./vmac-overview";
import { PageHeader } from "./vmac-ui";
import "./vmac-theme.css";
import "./native-guest-home.css";

export function NativeGuestHome({ setup = null }) {
  const { account } = useAccount();
  useEffect(() => { document.documentElement.classList.add("vmac-theme"); }, []);
  const [status, setStatus] = useState(null);
  const [page, setPage] = useState("overview");
  const [checksTab, setChecksTab] = useState("isolation");
  const [settings, setSettings] = useState(null);
  const [settingsVersion, setSettingsVersion] = useState(0);
  const loadedSettings = useRef(null);
  const pendingAnchor = useRef(null);
  const [profile, setProfile] = useState("");
  const [disk, setDisk] = useState(null);
  const diskSize = useRef(null);
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
  const currentPage = useRef("overview");
  // Which embedded settings sections hold edits that are not saved yet.
  const settingsDirty = useRef({});
  const proxyDirty = useRef(false);
  const pollNow = useRef(null);
  const lifecycleAction = useRef(null);
  const stopAction = useRef(null);

  function confirm(options) {
    return new Promise(resolve => setDialog({ ...options, resolve }));
  }
  function resolve(value) {
    dialog.resolve(value);
    setDialog(null);
  }
  function choosePage(value) {
    if (value !== currentPage.current) settingsDirty.current = {};
    if (settingsNeedReload({ entering: value, leaving: currentPage.current })) void refreshSettings();
    const changed = value !== currentPage.current;
    currentPage.current = value;
    // One page gives way to the next with a cross-fade where the browser can do it.
    if (changed && document.startViewTransition) document.startViewTransition(() => flushSync(() => setPage(value)));
    else setPage(value);
    // Keep the native sidebar selection in step with in-page navigation.
    void publishNavigation(latest.current).catch(() => {});
  }
  // The old settings sections live inside the pages now; their names still
  // work, and one that sits further down its page is scrolled into view.
  function openSettings(value = "network") {
    void navigate(pageFor(value), undefined, anchorFor(value));
  }
  // The embedded forms are rebuilt only when the settings really changed, so
  // a routine re-read leaves a form that is being edited alone.
  async function refreshSettings() {
    try {
      const next = await api("/settings");
      if (!settingsDiffer(loadedSettings.current, next)) return;
      loadedSettings.current = next;
      setSettings(next);
      setSettingsVersion(version => version + 1);
    } catch (failure) { setError(failure.message); }
  }
  useEffect(() => { void refreshSettings(); }, []);
  // Asks before unsaved work on the current page is dropped.
  async function confirmLeaving(target) {
    const prompts = leavePrompts({ from: currentPage.current, to: target,
      settingsDirty: Object.values(settingsDirty.current).some(Boolean), proxyDirty: proxyDirty.current });
    for (const prompt of prompts) {
      const question = prompt === "settings"
        ? { title: "放弃尚未保存的修改？", body: "当前环境不会改变。离开后会丢弃这次表单修改。", confirm: "放弃修改" }
        : { title: "离开代理线路？", body: "代理更改尚未应用。", confirm: "离开页面" };
      if (!await confirm(question)) return false;
      if (prompt === "proxy") proxyDirty.current = false;
    }
    return true;
  }
  async function openDesktop(destination = "desktop", shouldLaunchClaude = true) {
    if (opened.current) return;
    opened.current = true;
    try {
      // Showing the desktop returns the control center to the overview.
      if (!await confirmLeaving("overview")) return;
      automatic.current = false;
      setError("");
      setRequest(true);
      await native("showGuestDesktop", { destination });
      choosePage("overview");
      if (destination === "desktop" && shouldLaunchClaude && launchClaude.current) {
        launchClaude.current = false;
        void api("/macos/claude/window", { action: "launch" }).catch(() => {});
      }
    } catch (failure) { setError(failure.message); }
    finally { opened.current = false; setRequest(false); }
  }
  async function navigate(destination, checksSection, anchor) {
    if (opened.current) return;
    const target = pageFor(destination);
    if (!await confirmLeaving(target)) {
      // The native sidebar already shows the row that was clicked: put it back.
      await publishNavigation(latest.current);
      return;
    }
    automatic.current = false;
    setError("");
    if (target === "checks" && checksSection) setChecksTab(checksSection);
    // A jump within the page scrolls at once; one to another page scrolls
    // when that page is on screen.
    if (anchor && target === currentPage.current) followAnchor(anchor);
    else pendingAnchor.current = anchor || null;
    choosePage(target);
    if (opensDesktop(destination, { ready: latest.current?.ready, setup: setupActive.current })) await openDesktop();
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
      ...statusDetail(next, diskSize.current),
      ...shellStatus(next, { setup: setupActive.current }),
      destination: currentPage.current,
    });
  }
  useEffect(() => {
    let live = true;
    let timer;
    let wasRunning = false;
    let acknowledged = false;
    let lastNavigation = "";
    let jobWasRunning = false;
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
          // Opening VMac brings the guest up, like opening a laptop.
          if (shouldAutoStart(next, { enabled: autoStartEnabled(localStorage), installed: next.guest_system === "macos", setup: setupActive.current })) {
            void lifecycleAction.current?.("start");
          }
        }
        if (restartPending.current && (!next.vm_running || (next.job?.kind === "restart" && next.job.running))) restartPending.current = false;
        if (wasRunning && !next.vm_running) {
          choosePage("overview");
          void native("showGuestControls").catch(() => {});
        }
        wasRunning = next.vm_running;
        const jobRunning = Boolean(next.job?.running);
        if (settingsNeedReload({ entering: currentPage.current, leaving: currentPage.current, jobWasRunning, jobRunning })) void refreshSettings();
        jobWasRunning = jobRunning;
        const key = JSON.stringify([setupActive.current, next.vm_running, next.ready, next.job?.running, next.job?.error, statusDetail(next, diskSize.current), shellStatus(next, { setup: setupActive.current }).detail, currentPage.current]);
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
      void navigate("general");
    }
    function restartRequested() {
      restartPending.current = true;
      automatic.current = true;
      choosePage("overview");
    }
    function navigationRequested(event) {
      if (event.detail === "start" || event.detail === "restart") void lifecycleAction.current?.(event.detail);
      else if (event.detail === "stop") void stopAction.current?.();
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
    if (setupActive.current) { choosePage("overview"); return; }
    if (!latest.current || request || latest.current.job?.running) return;
    setError("");
    if (action === "start") {
      if (!await confirmLeaving("overview")) return;
      choosePage("overview");
      await start();
      return;
    }
    if (!latest.current.vm_running) return;
    if (!await confirmLeaving("overview")) return;
    setRequest(true);
    try {
      const accepted = await requestMacOSRecovery("restart", confirm);
      if (!accepted) return;
      choosePage("overview");
      restartPending.current = true;
      automatic.current = true;
      setStatus(current => ({ ...current, job: { ...accepted, running: true } }));
      void pollNow.current?.();
    } catch (failure) { setError(failure.message); }
    finally { setRequest(false); }
  };
  stopAction.current = stop;
  async function stop() {
    if (!latest.current?.vm_running || request || latest.current.job?.running) return;
    // A stopped guest brings the overview back, like a restart does.
    if (!await confirmLeaving("overview")) return;
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
  const lifecycle = page === "overview";
  const installed = status?.guest_system === "macos";
  useEffect(() => {
    if (!installed || disk) return;
    api("/macos/disk").then(setDisk).catch(() => {});
  }, [installed, Boolean(disk)]);
  // The toolbar's status popover shows the disk size too.
  useEffect(() => {
    diskSize.current = disk;
    void publishNavigation(latest.current).catch(() => {});
  }, [disk]);
  const network = status && networkState(status);
  const issue = error || (!status?.job?.running && (status?.job?.error || (status?.vm_running && status?.environment_update_error)));
  const showSetup = Boolean(setup && lifecycle);
  const pageKey = page;
  const scroller = useRef(null);
  // Scrolls a form into view and keeps it there: what sits above it may still
  // be loading and push it down, until the page settles or the user takes over.
  function followAnchor(id) {
    const view = scroller.current;
    if (!view || !document.getElementById(id)) return undefined;
    const follow = () => document.getElementById(id)?.scrollIntoView({ block: "start" });
    follow();
    const observer = new ResizeObserver(follow);
    const content = view.querySelector(".vm-page");
    if (content) observer.observe(content);
    const release = () => {
      observer.disconnect();
      clearTimeout(timer);
      for (const kind of ["wheel", "touchstart", "keydown", "mousedown"]) view.removeEventListener(kind, release);
    };
    const timer = setTimeout(release, 3000);
    for (const kind of ["wheel", "touchstart", "keydown", "mousedown"]) view.addEventListener(kind, release, { passive: true });
    return release;
  }
  // A page opens at its top, unless the jump named a form further down.
  useEffect(() => {
    const id = pendingAnchor.current;
    pendingAnchor.current = null;
    const release = id && followAnchor(id);
    if (!release) scroller.current?.scrollTo({ top: 0 });
    return release || undefined;
  }, [pageKey]);
  return <main ref={scroller} className={showSetup ? "native-guest-home native-setup-home" : "native-guest-home"}>
    {/* The overview is about the guest, which names itself in the middle of the page. */}
    {!showSetup && !lifecycle && <PageHeader title={pages[page].title} subtitle={pages[page].subtitle} />}
    {setup && <div className="native-setup-content" hidden={!showSetup}>{setup}</div>}
    {!showSetup && issue && <div className="vm-banner" role="alert"><CircleAlert size={17} aria-hidden="true" /><span>{issue}</span><button onClick={() => { setError(""); void pollNow.current?.(); void refreshSettings(); }}>重新检查</button></div>}
    {!showSetup && <div className="vm-page" key={pageKey}>
      {!status ? <div className="vm-skeleton" role="status" aria-label="正在读取客机状态"><span /><span /><span /></div> :
      lifecycle ? <GuestOverview name={profile || "macOS 客机"} status={status} network={network} request={request} disk={disk}
        onStart={() => lifecycleAction.current?.("start")} onRestart={() => lifecycleAction.current?.("restart")}
        onStop={stop} onOpen={() => openDesktop()} onNavigate={navigate} /> :
      page === "machines" ? <>
        <VMProfiles status={status} onConfirm={confirm} />
        {installed ? <DiskCapacity status={status} onConfirm={confirm} onChanged={() => { setDisk(null); void pollNow.current?.(); }} /> : <section className="vm-card vm-empty" aria-label="虚拟磁盘">
          <h2>还没有安装 macOS</h2><p>完成安装后，这里会显示磁盘容量、扩容和缓存清理。</p>
          <button className="primary" onClick={() => navigate("overview")}>打开安装向导</button>
        </section>}
        {installed && <SpaceManagement ready={status.ready && !status.job?.running} onConfirm={confirm} onStart={() => lifecycleAction.current?.("start")} running={status.vm_running} />}
      </> : page === "system" ? <>
        <GuestLoginDetails installed={installed} ready={status.ready && !status.job?.running} username={account?.macos_guest_user} passwordPending={account?.macos_password_pending} onConfirm={confirm} />
        <GuestTimezone status={status} installed={installed} settingsOpen={false}
          onSettings={() => document.getElementById("vmac-region")?.scrollIntoView({ behavior: "smooth", block: "start" })}
          onRestart={() => lifecycleAction.current?.("restart")} />
        <GuestInputSources ready={status.ready} onOpen={() => openDesktop("desktop", false)} />
      </> : page === "sharing" ? <SharingPage />
      : page === "general" ? <GeneralPage />
      : page === "checks" ? <ChecksPage status={status} protection={protection} tab={checksTab} onTabChange={setChecksTab}
          onConfirm={confirm} onSettings={openSettings} onInstall={setup && !installed ? () => navigate("overview") : undefined} />
      : page === "proxy" ? <ProxySettings status={status} onConfirm={confirm} onDirty={value => { proxyDirty.current = value; }}
          onApplied={() => { void pollNow.current?.(); void refreshSettings(); }} onChecks={() => navigate("checks", "gateway")} protection={protection} />
      : null}
      {status && settings && embeddedSections(page).map(id => <SettingsPanel key={`${id}:${settingsVersion}`} embedded sections={[id]}
        current={settings} status={status} onClose={() => {}} onConfirm={confirm} onSaved={refreshSettings} onOpenSection={openSettings}
        onDirtyChange={dirty => { settingsDirty.current[id] = dirty; }} />)}
    </div>}
    {dialog && <Modal title={dialog.title} onClose={() => resolve(false)}
      footer={<><button onClick={() => resolve(false)}>取消</button><button className="primary" onClick={() => resolve(true)}>{dialog.confirm}</button></>}>
      <div className="modal-body">{dialog.body}</div>
    </Modal>}
  </main>;
}
