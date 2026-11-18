import React, { useEffect, useState } from "react";
import { Check, HardDrive, LoaderCircle, Minus, Monitor, Plus, X } from "lucide-react";
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
