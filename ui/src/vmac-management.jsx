import React, { useEffect, useRef, useState } from "react";
import { Check, Clock3, Copy, Eye, EyeOff, HardDrive, Keyboard, KeyRound, LoaderCircle, Minus, Monitor, Plus, ShieldCheck, X } from "lucide-react";
import { api, native } from "./api";
import { StatusChip, gib } from "./vmac-ui";

async function waitForJob(accepted) {
  for (;;) {
    const job = await api("/agent/jobs/" + accepted.id);
    if (!job.running) {
      if (job.error) throw new Error(job.error);
      return;
    }
    await new Promise(resolve => setTimeout(resolve, 750));
  }
}

const maxGiB = 2048;

const inputSourceNames = {
  "com.apple.inputmethod.SCIM.ITABC": "简体拼音",
  "com.apple.inputmethod.TCIM.Zhuyin": "注音",
  "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese": "日语（罗马字）",
  "com.apple.inputmethod.Korean.2SetKorean": "韩语（两套式）",
};

export function GuestInputSources({ ready, onOpen }) {
  const [sources, setSources] = useState(null);
  const [error, setError] = useState("");
  const [request, setRequest] = useState(false);
  const [revision, refresh] = useState(0);

  useEffect(() => {
    if (!ready) return;
    const controller = new AbortController();
    api("/macos/input-sources", undefined, undefined, {}, { signal: controller.signal })
      .then(value => { if (!controller.signal.aborted) setSources(value); })
      .catch(failure => { if (!controller.signal.aborted) setError(failure.message); });
    return () => controller.abort();
  }, [ready, revision]);

  async function openSettings() {
    setRequest(true);
    setError("");
    try {
      await api("/macos/input-sources", {});
      await onOpen();
    } catch (failure) { setError(failure.message); }
    finally { setRequest(false); }
  }

  return <section className="vm-card" aria-label="客机输入法">
    <div className="vm-card-head"><div className="vm-card-title">
      <span className="vm-card-icon"><Keyboard size={17} aria-hidden="true" /></span>
      <div><h2>客机输入法</h2><p>{ready ? "在客机键盘设置中添加或移除输入法。在客机桌面按 Control + 空格切换。" : "启动并登录 macOS 客机后即可管理输入法。"}</p></div>
    </div></div>
    <p className="vm-note">在客机桌面里打字时，默认直接使用 Mac 上当前的输入法（例如豆包、搜狗），词库和设置都是 Mac 上那一份。客机这边请保持英文（ABC）输入，避免两边同时转换；不需要时可在「共享与传输」里关闭。</p>
    {ready && <>
      {sources && <dl className="vm-guest-details">
        <div><dt>当前输入法</dt><dd>{sources.selected.map(id => inputSourceNames[id] || id).join("、") || "暂未读取到"}</dd></div>
        <div><dt>已启用</dt><dd>{sources.enabled.map(id => inputSourceNames[id] || id).join("、") || "暂未读取到"}</dd></div>
      </dl>}
      <div className="vm-actions">
        <button className="primary" type="button" disabled={request} onClick={openSettings}>打开客机键盘设置</button>
        <button type="button" onClick={() => { setError(""); refresh(value => value + 1); }}>刷新</button>
      </div>
    </>}
    {error && ready && <p className="vm-error" role="alert">{error}</p>}
  </section>;
}

export function GuestLoginDetails({ installed, ready, username, passwordPending, onConfirm }) {
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [admin, setAdmin] = useState(null);
  const [adminPending, setAdminPending] = useState(false);
  const request = useRef(null);

  useEffect(() => () => request.current?.abort(), []);
  useEffect(() => {
    if (!installed || !ready) { setAdmin(null); return; }
    const controller = new AbortController();
    api("/macos/guest-admin", undefined, undefined, {}, { signal: controller.signal })
      .then(value => { if (!controller.signal.aborted) setAdmin(value.admin); })
      .catch(failure => { if (!controller.signal.aborted) setError(failure.message); });
    return () => controller.abort();
  }, [installed, ready]);
  async function changeAdmin(enabled) {
    const name = username || "客机账户";
    const confirmed = await onConfirm(enabled ? {
      title: "开启客机管理员权限？",
      body: `开启后，安装应用或修改系统设置时，用 ${name} 和 VMac 账户密码认证即可。客机里的程序也能修改系统设置（例如 DNS），客机内的部分检测可能被绕过；外网出口仍由 Mac 端网关控制。`,
      confirm: "开启管理员权限",
    } : {
      title: "关闭客机管理员权限？",
      body: `关闭后 ${name} 变回普通用户，需要管理员认证的安装和设置会无法完成。`,
      confirm: "关闭管理员权限",
    });
    if (!confirmed) return;
    setAdminPending(true);
    setNotice("");
    setError("");
    try {
      const result = await api("/macos/guest-admin", { enabled });
      setAdmin(result.admin);
      setNotice(result.admin ? "管理员权限已开启" : "管理员权限已关闭");
    } catch (failure) { setError(failure.message); }
    finally { setAdminPending(false); }
  }
  useEffect(() => {
    if (!password) return;
    const timer = setTimeout(() => setPassword(""), 30_000);
    return () => clearTimeout(timer);
  }, [password]);

  async function reveal() {
    if (request.current) return;
    const controller = new AbortController();
    request.current = controller;
    setLoading(true);
    setNotice("");
    setError("");
    try {
      const result = await api("/macos/login", { action: "show-password" }, undefined, {}, { signal: controller.signal });
      if (!controller.signal.aborted) setPassword(result.password);
    } catch (failure) {
      if (!controller.signal.aborted) setError(failure.message);
    } finally {
      request.current = null;
      if (!controller.signal.aborted) setLoading(false);
    }
  }
  async function copyPassword() {
    setNotice("");
    setError("");
    try {
      await native("clipboardWrite", { text: password, confidential: true });
      setNotice("密码已复制");
    } catch {
      setError("无法复制密码，请检查剪贴板权限。");
    }
  }

  return <section className="vm-card" aria-label="macOS 客机登录信息">
    <div className="vm-card-head">
      <div className="vm-card-title"><span className="vm-card-icon"><KeyRound size={17} aria-hidden="true" /></span>
        <div><h2>macOS 客机登录信息</h2><p>{installed ? "用于登录当前虚拟机的 macOS。" : "完成 macOS 安装后即可查看。"}</p></div>
      </div>
    </div>
    {installed && <>
      <dl className="vm-guest-details">
        <div><dt>用户名</dt><dd>{username ? <code>{username}</code> : "暂未读取到"}</dd></div>
        <div><dt>密码</dt><dd>{password ? <code>{password}</code> : <span aria-label="密码已隐藏">••••••••</span>}</dd></div>
        <div><dt>管理员权限</dt><dd>{admin === null ? (ready ? "正在读取…" : "启动客机后可查看") : admin ? "已开启" : "未开启"}</dd></div>
      </dl>
      {passwordPending && <p className="vm-note">客机密码待同步，请使用上次确认的密码。</p>}
      <p className="vm-note">{admin === false
        ? "当前是普通用户，安装应用时的管理员认证会失败。开启管理员权限后，用上面的用户名和密码认证。"
        : "安装应用或修改系统设置要求管理员认证时，输入上面的用户名和密码。安装时出现的 cagesetup 只在首次设置期间有效。"}</p>
      <div className="vm-actions">
        {password ? <>
          <button type="button" onClick={() => setPassword("")}><EyeOff size={15} aria-hidden="true" />隐藏密码</button>
          <button type="button" onClick={copyPassword}><Copy size={15} aria-hidden="true" />复制密码</button>
          <span className="vm-note">30 秒后隐藏</span>
        </> : <button type="button" disabled={loading} onClick={reveal}>
          {loading ? <LoaderCircle size={15} className="spin" aria-hidden="true" /> : <Eye size={15} aria-hidden="true" />}
          {loading ? "正在读取…" : "查看密码"}
        </button>}
        {admin === false && <button type="button" className="primary" disabled={adminPending || !ready} onClick={() => changeAdmin(true)}>
          {adminPending ? <LoaderCircle size={15} className="spin" aria-hidden="true" /> : <ShieldCheck size={15} aria-hidden="true" />}开启管理员权限
        </button>}
        {admin === true && <button type="button" className="vm-quiet" disabled={adminPending || !ready} onClick={() => changeAdmin(false)}>
          {adminPending && <LoaderCircle size={15} className="spin" aria-hidden="true" />}关闭管理员权限
        </button>}
      </div>
      {notice && <p className="vm-success" role="status">{notice}</p>}
      {error && <p className="vm-error" role="alert">{error}</p>}
    </>}
  </section>;
}

const timezoneKey = zone => ["+00:00", "GMT", "UTC", "Etc/GMT", "Etc/UTC"].includes(zone) ? "UTC" : zone;

export function GuestTimezone({ status, installed, settingsOpen, onSettings, onRestart }) {
  const [timezone, setTimezone] = useState("");
  const [error, setError] = useState("");
  const busy = Boolean(status.job?.running);
  const automatic = status.auto_timezone;
  const suggested = status.location?.timezone;
  const pending = automatic && timezone && suggested && timezoneKey(timezone) !== timezoneKey(suggested);

  useEffect(() => {
    if (!installed || busy || settingsOpen) return;
    const controller = new AbortController();
    api("/settings", undefined, undefined, {}, { signal: controller.signal }).then(value => {
      if (!controller.signal.aborted) {
        setTimezone(value.timezone);
        setError("");
      }
    }).catch(failure => { if (!controller.signal.aborted) setError(failure.message); });
    return () => controller.abort();
  }, [installed, busy, status.job?.id, settingsOpen]);

  return <section className="vm-card" aria-label="时区自动适配">
    <div className="vm-card-head">
      <div className="vm-card-title"><span className="vm-card-icon"><Clock3 size={17} aria-hidden="true" /></span>
        <div><h2>时区自动适配</h2><p>{installed ? "启动或重启客机时，按当前代理出口匹配时区。" : "完成 macOS 安装后即可设置。"}</p></div>
      </div>
      {installed && <StatusChip tone={pending ? "warn" : automatic ? "ok" : "idle"}>{pending ? "待应用" : automatic ? "跟随出口" : "手动"}</StatusChip>}
    </div>
    {installed && <>
      <dl className="vm-guest-details">
        <div><dt>已配置时区</dt><dd>{timezone ? <code>{timezone}</code> : error ? "未读取" : "正在读取…"}</dd></div>
        <div><dt>出口时区</dt><dd>{suggested ? <code>{suggested}</code> : "等待检测"}</dd></div>
      </dl>
      <div className="vm-actions">
        <button type="button" onClick={onSettings}>时区与语言设置</button>
        {pending && status.vm_running && <button type="button" className="primary" disabled={busy} onClick={onRestart}>重启并应用</button>}
      </div>
      {error && <p className="vm-error" role="alert">{error}</p>}
    </>}
  </section>;
}

export function DiskCapacity({ status, onConfirm, onChanged }) {
  const [disk, setDisk] = useState(null);
  const [size, setSize] = useState("");
  const [pending, setPending] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  async function readDisk() {
    const value = await api("/macos/disk");
    setDisk(value);
    return value;
  }
  useEffect(() => { readDisk().catch(failure => setError(failure.message)); }, []);
  const current = disk ? disk.bytes / 2 ** 30 : 0;
  const minimum = Math.floor(current) + 1;
  const expanded = Number(size);
  const valid = Number.isInteger(expanded) && expanded > current && expanded <= maxGiB;
  const locked = pending || Boolean(status.job?.running);
  const nudge = delta => setSize(String(Math.min(maxGiB, Math.max(minimum, (Number(size) || Math.ceil(current)) + delta))));
  async function grow(event) {
    event.preventDefault();
    if (!disk?.expandable || !valid) return;
    if (!await onConfirm({
      title: `将磁盘扩大到 ${expanded} GiB？`,
      body: status.vm_running
        ? "请先保存客机中的工作。VMac 将停止客机，在镜像副本上扩容，并保留原镜像。完成后可在客机桌面页重新启动。"
        : "VMac 会在磁盘副本上扩容，并保留原镜像。",
      confirm: "扩大磁盘",
    })) return;
    setError("");
    setNotice("");
    setPending(true);
    try {
      await waitForJob(await api("/macos/disk", { gib: expanded }));
      const updated = await readDisk();
      setSize("");
      setNotice(`磁盘容量已调整为 ${gib(updated.bytes)} GiB。启动客机后可检查可用空间。`);
    } catch (failure) { setError(failure.message); }
    finally { setPending(false); onChanged?.(); }
  }
  return <section className="vm-card vm-disk" aria-label="虚拟磁盘">
    <div className="vm-card-head">
      <div className="vm-card-title"><span className="vm-card-icon"><HardDrive size={17} /></span>
        <div><h2>虚拟磁盘</h2><p>扩容在镜像副本上进行，完成验证后替换，原镜像保留为备份。</p></div>
      </div>
      <div className="vm-figure">{disk ? <><strong>{gib(disk.bytes)}</strong><small>GiB</small></> : error ? <small>—</small> : <LoaderCircle size={18} className="spin" />}</div>
    </div>
    {disk && (disk.expandable ? <form className="vm-grow" onSubmit={grow}>
      <label htmlFor="vm-grow-size">目标容量</label>
      <div className="vm-stepper">
        <button type="button" aria-label="减少 1 GiB" onClick={() => nudge(-1)} disabled={locked || !size || expanded <= minimum}><Minus size={14} /></button>
        <input id="vm-grow-size" type="number" inputMode="numeric" min={minimum} max={maxGiB} step="1" placeholder={String(minimum)} value={size}
          onChange={event => setSize(event.target.value)} disabled={locked} required />
        <span>GiB</span>
        <button type="button" aria-label="增加 1 GiB" onClick={() => nudge(1)} disabled={locked || expanded >= maxGiB}><Plus size={14} /></button>
      </div>
      <div className="vm-presets" role="group" aria-label="快速选择">
        {[16, 32, 64].map(step => <button type="button" key={step} disabled={locked || Math.ceil(current) + step > maxGiB}
          aria-pressed={expanded === Math.ceil(current) + step} onClick={() => setSize(String(Math.ceil(current) + step))}>+{step}</button>)}
      </div>
      <button className="primary" disabled={locked || !valid}>{pending ? <><LoaderCircle size={14} className="spin" />正在扩容…</> : "扩大磁盘"}</button>
    </form> : <p className="vm-note">当前镜像格式不支持在 VMac 内扩容。</p>)}
    {notice && <p className="vm-success" role="status"><Check size={14} />{notice}</p>}
    {error && <p className="vm-error" role="alert">{error}</p>}
  </section>;
}

export function VMProfiles({ status, onConfirm }) {
  const [profiles, setProfiles] = useState(null);
  const [name, setName] = useState("");
  const [adding, setAdding] = useState(false);
  const [pending, setPending] = useState("");
  const [error, setError] = useState("");
  useEffect(() => {
    native("vmacProfiles").then(setProfiles).catch(failure => setError(failure.message));
  }, []);
  async function create(event) {
    event.preventDefault();
    if (!name.trim()) return;
    setPending("create"); setError("");
    try {
      setProfiles(await native("vmacCreateProfile", { name: name.trim() }));
      setName("");
      setAdding(false);
    } catch (failure) { setError(failure.message); }
    finally { setPending(""); }
  }
  async function switchTo(profile) {
    if (!await onConfirm({
      title: `切换到「${profile.name}」？`,
      body: status.vm_running ? "请保存客机中的工作。VMac 会先停止当前客机，再重新打开到所选环境。" : "VMac 会重新打开到所选环境。",
      confirm: "切换虚拟机",
    })) return;
    setPending(profile.id); setError("");
    try {
      if (status.vm_running) await waitForJob(await api("/stop", {}));
      await native("vmacSwitchProfile", { id: profile.id });
    } catch (failure) { setError(failure.message); setPending(""); }
  }
  return <section className="vm-card vm-profiles-card">
    <div className="vm-card-head">
      <div><h2>虚拟机</h2><p>所有客机共用 VMac 账户和代理。每台客机保留独立的磁盘、安装进度和文件授权。</p></div>
      {!adding && <button onClick={() => setAdding(true)} disabled={Boolean(pending)}><Plus size={14} />新建虚拟机</button>}
    </div>
    {adding && <form className="vm-inline-form" onSubmit={create}>
      <input aria-label="新虚拟机名称" placeholder="为新客机命名，例如：测试客机" value={name} maxLength={36} autoFocus
        onChange={event => setName(event.target.value)} onKeyDown={event => { if (event.key === "Escape") { setAdding(false); setName(""); } }} />
      <button className="primary" disabled={Boolean(pending) || !name.trim()}>{pending === "create" ? <LoaderCircle size={14} className="spin" /> : <Check size={14} />}添加</button>
      <button type="button" className="vm-quiet" aria-label="取消" onClick={() => { setAdding(false); setName(""); }}><X size={14} /></button>
    </form>}
    {!profiles && !error && <div className="vm-skeleton compact"><span /><span /></div>}
    {profiles && <ul className="vm-profiles">{profiles.items.map(profile => {
      const active = profile.id === profiles.active;
      return <li key={profile.id} className={active ? "active" : ""}>
        <span className="vm-profile-icon"><Monitor size={18} /></span>
        <div className="vm-profile-text"><strong>{profile.name}</strong><small>{profile.installed ? "已安装 macOS" : "等待安装 · 切换后进入安装向导"}</small></div>
        {active ? <StatusChip tone="ok">当前客机</StatusChip>
          : <button onClick={() => switchTo(profile)} disabled={Boolean(pending) || status.job?.running}>
            {pending === profile.id ? <><LoaderCircle size={14} className="spin" />正在切换…</> : "切换"}
          </button>}
      </li>;
    })}</ul>}
    {error && <p className="vm-error" role="alert">{error}</p>}
  </section>;
}
