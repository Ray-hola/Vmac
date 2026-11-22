import React, { useEffect, useRef, useState } from "react";
import { Check, LoaderCircle } from "lucide-react";
import { api, native, nativeAvailable } from "./api";
import { useAccount } from "./account";
import { MacOSLogin } from "./macos-login";
import { DiagnosticSettings } from "./diagnostics.jsx";
import { ScreenSharingChecks } from "./macos-screen-sharing";
import { Modal } from "./modal";
import "./initialization.css";

const steps = [
  { id: "screen", label: "窗口录制", hint: "开启 VMac 窗口组件的窗口录制权限。若系统提示重新打开，按提示操作。" },
  { id: "input", label: "辅助功能", hint: "开启 VMac 窗口组件的辅助功能权限，以便操作客机窗口。" },
  { id: "projects", label: "文件系统扩展", hint: "可查看 macFUSE 和 macFUSE (local)。仅主动上传的环境会验证没有宿主目录挂载。" },
  { id: "sharing", label: "屏幕共享", hint: "在客机系统设置中开启屏幕共享，并允许当前客机账户连接。" },
];

async function setupRequest(action) {
  const lifecycle = action === "start" || action === "stop";
  const body = action === "start" ? { guest_system: "macos" } : action === "stop" ? {} : { action };
  const signal = AbortSignal.timeout(action === "finish" ? 60000 : 35000);
  const result = await api(lifecycle ? `/${action}` : "/macos/first-setup", body, undefined, {}, { signal });
  if (result.error) throw new Error(result.error);
  return result;
}

export function MacOSFirstSetup() {
  const { account, refresh } = useAccount();
  const [state, setState] = useState(null);
  const [permissions, setPermissions] = useState(null);
  const [selected, setSelected] = useState(null);
  const [openRequest, setOpenRequest] = useState(0);
  const [operation, setOperation] = useState("");
  const [error, setError] = useState("");
  const [statusError, setStatusError] = useState("");
  const [diagnostics, setDiagnostics] = useState(false);
  const [details, setDetails] = useState(false);
  const inFlight = useRef(false);

  useEffect(() => {
    let active = true;
    let timer;
    async function readBootStatus() {
      try {
        const signal = AbortSignal.timeout(12000);
        const next = await api("/status", undefined, undefined, {}, { signal });
        if (active) { setState(next); setStatusError(""); }
      } catch (failure) {
        if (active) setStatusError(failure.message);
      } finally {
        if (active) timer = setTimeout(readBootStatus, 2000);
      }
    }
    void readBootStatus();
    const ownsLifecycle = !window.cageNativeVMWorkbench;
    if (ownsLifecycle) {
      window.cageWorkbenchAction = async command => {
        if (command === "closeTab") document.dispatchEvent(new Event("cage-close-modal"));
        if (command === "quit") await native("quitNow");
      };
      window.cageEditAction = () => false;
      if (nativeAvailable()) native("workbenchReady").catch(() => {});
    }
    return () => {
      active = false;
      clearTimeout(timer);
      if (ownsLifecycle) {
        delete window.cageWorkbenchAction;
        delete window.cageEditAction;
      }
    };
  }, []);

  async function act(action, step) {
    if (inFlight.current) return;
    inFlight.current = true;
    setOperation(action);
    setError("");
    try {
      if (step) {
        setSelected(step);
        setPermissions(null);
      } else if (action !== "finish") setPermissions(null);
      if (action === "confirm-sharing") {
        setPermissions(await setupRequest(action));
      } else {
        await setupRequest(action);
        if (step) setOpenRequest(value => value + 1);
        if (action === "finish") await refresh();
      }
    } catch (failure) {
      if (action === "finish" && failure.status === 410) await refresh();
      else setError(failure.name === "TimeoutError" ? "客机响应超时。请核对当前页面后重试。" : failure.message);
    } finally {
      inFlight.current = false;
      setOperation("");
    }
  }

  const busy = Boolean(operation);
  const running = Boolean(state?.job?.running);
  const canOperate = Boolean(state?.ready && !account.macos_password_pending && !running && !busy);
  const verified = Boolean(permissions && steps.every(({ id }) => permissions[id]));
  const progress = !state ? "正在读取启动状态…" :
    running ? state.job.message || "正在启动虚拟 Mac…" :
    account.macos_password_pending ? "客机密码尚未同步。" :
    !state.vm_running ? "虚拟 Mac 尚未启动。" :
    !state.ready ? "虚拟 Mac 已启动，正在等待客机连接。" :
    operation === "confirm-sharing" ? "正在检测四项授权和共享状态…" :
    operation === "finish" ? "正在完成系统设置…" :
    verified ? "四项检查已通过。现在可以进入工作台。" :
    permissions ? "请处理未通过的项目，再运行统一检测。" :
    "完成所需授权后，点击「统一检测」。";
  const jobError = !running && state?.job?.error;
  const failure = error || statusError || (!state?.ready && jobError);

  return <main className="initialization"><section className="initialization-content mac-setup-content">
    <div className="initialization-title">
      <p className="mac-setup-eyebrow">安装与检查 · macOS 系统权限</p>
      <h1>完成虚拟 Mac 的系统授权</h1>
      <p>按需打开各项设置，在客机内确认授权后返回这里。</p>
    </div>
    <ol className="mac-setup-checklist" aria-label="系统授权步骤">
      {steps.map((step, index) => <li key={step.id} data-complete={Boolean(permissions?.[step.id])} aria-current={selected?.id === step.id ? "step" : undefined}>
        <span className="mac-setup-marker">{permissions?.[step.id] ? <Check size={16} aria-hidden="true" /> : index + 1}</span>
        <div className="mac-setup-step">
          <span>{step.label}</span>
          <small>{step.hint}</small>
          {step.id === "projects" && permissions?.projects_error && <small role="alert">{permissions.projects_error}</small>}
        </div>
        <small className="mac-setup-step-status">{permissions?.[step.id] ? (step.id === "projects" && permissions.upload_only ? "无宿主共享" : "已通过") : permissions ? "未通过" : "未检测"}</small>
        <button type="button" disabled={!canOperate} onClick={() => act(step.id, step)}>打开{step.label}</button>
      </li>)}
    </ol>
    <section className="initialization-operation mac-setup-task" aria-label="授权结果">
      <h2>授权结果</h2>
      <p role="status">{busy && <LoaderCircle size={16} className="spin" aria-hidden="true" />} {progress}</p>
      {permissions?.sharing_checks && <ScreenSharingChecks checks={permissions.sharing_checks} summary={permissions.sharing_summary} />}
      <div className="initialization-recovery">
        {state && !running && (!state.ready || account.macos_password_pending) &&
          <button type="button" disabled={busy} onClick={() => act("start")}>{account.macos_password_pending ? "重试同步客机密码" : "启动并连接客机"}</button>}
        {running && <button type="button" disabled={busy} onClick={() => act("stop")}>停止当前操作</button>}
        <button type="button" className={verified ? undefined : "primary"} disabled={!canOperate} onClick={() => act("confirm-sharing")}>统一检测</button>
        {verified && <button type="button" className="primary" disabled={!canOperate} onClick={() => act("finish")}>进入工作台</button>}
      </div>
      {state?.vm_running && <MacOSLogin initialSetup openRequest={openRequest} managedCredential={account.macos_credentials_ready} disabled={busy || running}
        onSessionClosed={() => setSelected(null)} label="打开客机画面" setupHint={selected?.hint}
        setupStatus={failure || progress} setupError={Boolean(failure)} />}
    </section>
    {failure && <section className="initialization-notice" role="alert"><h2>操作未完成</h2><p>{failure}</p></section>}
    <details className="mac-setup-help"><summary>管理员授权帮助</summary>
      <p>如果客机要求管理员认证，用户名为 <strong>vmacsetup</strong>（用旧版本开始安装的客机是 <strong>cagesetup</strong>）。可在客机画面选中密码框，再点击「填写授权密码」，然后在客机内确认授权。</p>
    </details>
    <div className="initialization-support"><button className="text-button" onClick={() => setDetails(true)}>查看操作详情</button><button className="text-button" onClick={() => setDiagnostics(!diagnostics)}>日志与诊断</button></div>
    {diagnostics && <DiagnosticSettings />}
    {details && <Modal title="系统设置操作详情" onClose={() => setDetails(false)}><div className="modal-body"><p>{progress}</p>{(failure || jobError) && <p role="alert">{failure || jobError}</p>}<pre className="job-log">{state?.job?.log || "查看「日志与诊断」可导出完整记录。"}</pre></div></Modal>}
  </section></main>;
}
