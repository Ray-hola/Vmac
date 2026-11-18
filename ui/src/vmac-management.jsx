import React, { useEffect, useState } from "react";
import { api, native } from "./api";

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
  const expanded = Number(size);
  async function grow(event) {
    event.preventDefault();
    if (!disk?.expandable || !Number.isInteger(expanded) || expanded <= current) return;
    if (!await onConfirm({
      title: `将磁盘扩大到 ${expanded} GiB？`,
      body: status.vm_running
        ? "请先保存客机中的工作。VMac 将停止客机，在镜像副本上扩容，并保留原镜像。完成后可用顶部按钮启动客机。"
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
      setNotice(`磁盘容量已调整为 ${updated.bytes / 2 ** 30} GiB。可启动客机检查可用空间。`);
    } catch (failure) { setError(failure.message); }
    finally { setPending(false); onChanged?.(); }
  }
  return <section className="vmac-section" aria-label="虚拟磁盘">
    <h2>虚拟磁盘</h2>
    {disk ? <p>当前容量 <span className="vmac-reading">{Number(current.toFixed(2))} GiB</span></p> : !error && <p role="status">正在读取磁盘容量…</p>}
    {disk && (disk.expandable ? <form className="vmac-form-row" onSubmit={grow}>
      <label>目标容量 <input type="number" min={Math.floor(current) + 1} max="2048" step="1" value={size} onChange={event => setSize(event.target.value)} disabled={pending || status.job?.running} required /> GiB</label>
      <button disabled={pending || status.job?.running || !size || expanded <= current}>{pending ? "正在扩容…" : "扩大磁盘"}</button>
    </form> : <p>当前镜像格式不支持在 VMac 内扩容。</p>)}
    {notice && <p role="status">{notice}</p>}
    {error && <p role="alert">{error}</p>}
  </section>;
}

export function VMProfiles({ status, onConfirm }) {
  const [profiles, setProfiles] = useState(null);
  const [name, setName] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    native("vmacProfiles").then(setProfiles).catch(failure => setError(failure.message));
  }, []);
  async function create(event) {
    event.preventDefault();
    if (!name.trim()) return;
    setPending(true); setError("");
    try {
      setProfiles(await native("vmacCreateProfile", { name: name.trim() }));
      setName("");
    } catch (failure) { setError(failure.message); }
    finally { setPending(false); }
  }
  async function switchTo(profile) {
    if (!await onConfirm({
      title: `切换到「${profile.name}」？`,
      body: status.vm_running ? "请保存客机中的工作。VMac 会先停止当前客机，再重新打开到所选环境。" : "VMac 会重新打开到所选环境。",
      confirm: "切换虚拟机",
    })) return;
    setPending(true); setError("");
    try {
      if (status.vm_running) await waitForJob(await api("/stop", {}));
      await native("vmacSwitchProfile", { id: profile.id });
    } catch (failure) { setError(failure.message); setPending(false); }
  }
  return <section className="vmac-section">
    <h2>虚拟机切换</h2>
    <p>所有客机共用 VMac 账户和代理。每台 macOS 客机保留独立的磁盘、安装进度和文件授权。</p>
    {profiles && <ul className="vmac-profiles">{profiles.items.map(profile => <li className="vmac-row" key={profile.id}>
      <div><strong>{profile.name}</strong><small>{profile.installed ? "已安装 macOS" : "等待安装"}</small></div>
      {profile.id === profiles.active ? <span>当前客机</span> : <button onClick={() => switchTo(profile)} disabled={pending || status.job?.running}>切换</button>}
    </li>)}</ul>}
    <form className="vmac-form-row" onSubmit={create}>
      <label>新虚拟机名称 <input value={name} maxLength={36} onChange={event => setName(event.target.value)} required /></label>
      <button disabled={pending || !name.trim()}>添加虚拟机</button>
    </form>
    {pending && <p role="status">正在处理虚拟机配置…</p>}
    {error && <p role="alert">{error}</p>}
  </section>;
}
