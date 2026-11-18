import React, { useState } from "react";
import { Check, LoaderCircle, Play, ScanSearch, Sparkles, Trash2 } from "lucide-react";
import { api } from "./api";
import "./space-management.css";

const bytes = n => n >= 1073741824 ? `${(n / 1073741824).toFixed(2)} GB` : n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.ceil(n / 1024)} KB`;
const stages = ["扫描", "审阅", "移入废纸篓"];

export function SpaceManagement({ ready, running, onConfirm, onStart }) {
  const [plan, setPlan] = useState(null);
  const [selected, setSelected] = useState([]);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [results, setResults] = useState(null);
  const [consumed, setConsumed] = useState(false);
  const selectable = plan?.items.filter(item => !item.blocked && item.bytes > 0) || [];
  const selectedBytes = selectable.filter(item => selected.includes(item.id)).reduce((n, item) => n + item.bytes, 0);
  const reviewable = selectable.reduce((n, item) => n + item.bytes, 0);
  const allSelected = selectable.length > 0 && selectable.every(item => selected.includes(item.id));
  const stage = results ? 2 : plan ? 1 : 0;
  async function scan() {
    setBusy("scan"); setError(""); setResults(null); setSelected([]); setPlan(null);
    try { setPlan(await api("/macos/space/scan", {})); setConsumed(false); }
    catch (failure) { setError(failure.message); }
    finally { setBusy(""); }
  }
  async function clean() {
    if (!await onConfirm({ title: "将所选项目移入客机废纸篓？", body: `共 ${selected.length} 项，约 ${bytes(selectedBytes)}。缓存可能需要重新生成。内容有变化、正在使用或受 Mole 保护的项目会保留。移入废纸篓可恢复；清空客机废纸篓后才会释放磁盘空间。`, confirm: "移入客机废纸篓" })) return;
    setBusy("clean"); setError(""); setConsumed(true);
    try { setResults(await api("/macos/space/clean", { plan: plan.id, ids: selected })); setSelected([]); }
    catch (failure) { setError(`${failure.message} 请重新扫描后检查结果。`); }
    finally { setBusy(""); }
  }
  const locked = Boolean(busy) || consumed;
  return <section className="vm-card space-manager" aria-label="客机空间管理">
    <div className="vm-card-head">
      <div className="vm-card-title"><span className="vm-card-icon"><Sparkles size={17} /></span>
        <div><h2>Mole 清理</h2><p>检查客机里的应用缓存与日志。文档、登录数据、应用安装和系统目录保留。</p></div>
      </div>
      <ol className="space-stages" aria-label="清理步骤">
        {stages.map((label, index) => <li key={label} className={index < stage ? "done" : index === stage ? "current" : ""}>
          <span>{index < stage ? <Check size={11} strokeWidth={3} /> : index + 1}</span>{label}
        </li>)}
      </ol>
    </div>
    {plan?.capacity > 0 && <div className="space-disk">
      <div><strong>客机磁盘</strong><span>已用 {bytes(plan.capacity - plan.available)} · 可用 {bytes(plan.available)} / {bytes(plan.capacity)}</span></div>
      <div className="space-meter" role="meter" aria-label="客机磁盘已用空间" aria-valuemin={0} aria-valuemax={plan.capacity} aria-valuenow={plan.capacity - plan.available}>
        <i style={{ width: `${(plan.capacity - plan.available) / plan.capacity * 100}%` }} />
        {selectedBytes > 0 && <b style={{ width: `${selectedBytes / plan.capacity * 100}%`, left: `${(plan.capacity - plan.available - selectedBytes) / plan.capacity * 100}%` }} />}
      </div>
    </div>}
    {!ready && <div className="space-gate" role="status">
      <span>{running ? "客机正在启动，登录完成后即可扫描。" : "扫描在客机内运行，请先启动并登录 macOS 客机。"}</span>
      {!running && onStart && <button onClick={onStart}><Play size={13} fill="currentColor" />启动客机</button>}
    </div>}
    <div className="space-actions">
      <button className={plan ? "" : "primary"} disabled={!ready || Boolean(busy)} onClick={scan}>
        {busy === "scan" ? <LoaderCircle size={14} className="spin" /> : <ScanSearch size={15} />}
        {busy === "scan" ? "正在扫描客机…" : plan ? "重新扫描" : "扫描客机空间"}
      </button>
      {plan && <span>{plan.items.length} 项 · 可审阅 {bytes(reviewable)}</span>}
    </div>
    {busy === "scan" && <div className="space-scanning" role="status"><i /><span>正在读取客机目录并运行 Mole 安全检查，最多约 100 秒。</span></div>}
    {busy === "clean" && <p className="space-note" role="status"><LoaderCircle size={14} className="spin" />正在逐项复查并移入客机废纸篓…</p>}
    {error && <p className="vm-error" role="alert">{error}</p>}
    {plan?.warnings.map((warning, index) => <p className="space-note" key={index}>{warning}</p>)}
    {results && <div className="space-results" role="status">
      <strong><Check size={15} />已移入废纸篓 {results.filter(item => item.trashed).length} 项</strong>
      {results.filter(item => !item.trashed).map(item => <p key={item.id}>{item.name}：{item.error}</p>)}
      <p>可在客机废纸篓恢复。清空废纸篓后才会释放空间，重新扫描以查看最新结果。</p>
    </div>}
    {plan && <>
      <div className="space-list-header">
        <label className="space-select-all">
          <input type="checkbox" checked={allSelected} disabled={locked || !selectable.length}
            ref={node => { if (node) node.indeterminate = selected.length > 0 && !allSelected; }}
            onChange={event => setSelected(event.target.checked ? selectable.map(item => item.id) : [])} />
          全选可清理项
        </label>
        <span>{new Date(plan.created_at).toLocaleTimeString("zh-CN", { hour12: false })} 扫描 · 清单 30 分钟有效</span>
      </div>
      {plan.items.length === 0 ? <p className="space-note">当前范围内没有可列出的缓存或日志。</p> : <ul className="space-list">{plan.items.map((item, index) => <li key={item.id} className={item.blocked ? "protected" : ""} style={{ "--i": Math.min(index, 12) }}>
        <label><input type="checkbox" disabled={locked || !!item.blocked || item.bytes === 0} checked={selected.includes(item.id)} onChange={event => setSelected(ids => event.target.checked ? [...ids, item.id] : ids.filter(id => id !== item.id))} />
          <span><strong>{item.name}</strong><small>{item.category} · {item.path}</small>{item.blocked && <small className="space-protected">{item.blocked}</small>}</span>
          <span className="space-size">{item.blocked ? "保留" : bytes(item.bytes)}</span></label>
      </li>)}</ul>}
      <div className={`space-review ${selected.length ? "armed" : ""}`}>
        <span>{selected.length ? <>已选 <strong>{selected.length}</strong> 项 · {bytes(selectedBytes)}</> : consumed ? "本次清单已使用，重新扫描后可再次清理" : "勾选要清理的项目"}</span>
        <button className="primary" disabled={!!busy || !ready || consumed || selected.length === 0} onClick={clean}><Trash2 size={14} />审阅并移入废纸篓</button>
      </div>
      <p className="space-footnote">{plan.engine}。仅在当前客机内运行；不读取主机目录，不自动清空废纸篓。</p>
    </>}
  </section>;
}
