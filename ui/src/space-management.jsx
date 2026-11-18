import React, { useState } from "react";
import { api } from "./api";
import "./space-management.css";

const bytes = n => n >= 1073741824 ? `${(n / 1073741824).toFixed(2)} GB` : n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.ceil(n / 1024)} KB`;

export function SpaceManagement({ ready, onConfirm }) {
  const [plan, setPlan] = useState(null);
  const [selected, setSelected] = useState([]);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [results, setResults] = useState(null);
  const [consumed, setConsumed] = useState(false);
  const selectable = plan?.items.filter(item => !item.blocked && item.bytes > 0) || [];
  const selectedBytes = selectable.filter(item => selected.includes(item.id)).reduce((n, item) => n + item.bytes, 0);
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
  return <section className="space-manager" aria-label="客机空间管理">
    <div className="space-intro"><h2>Mole 清理</h2><p>由 Mole 检查应用缓存与日志。文档、登录数据、应用安装和系统目录保留。</p></div>
    {plan?.capacity > 0 && <div className="space-disk"><div><strong>客机磁盘</strong><span>可用 {bytes(plan.available)} / {bytes(plan.capacity)}</span></div><meter min="0" max={plan.capacity} value={plan.capacity - plan.available} aria-label="客机磁盘已用空间" /></div>}
    <div className="space-actions"><button className="primary" disabled={!ready || !!busy} onClick={scan}>{busy === "scan" ? "正在扫描客机…" : plan ? "重新扫描" : "扫描客机空间"}</button>{plan && <span>{plan.items.length} 项 · 可审阅 {bytes(selectable.reduce((n, item) => n + item.bytes, 0))}</span>}</div>
    {!ready && <p role="status">请使用顶部“启动”按钮启动并登录 macOS 客机。</p>}
    {busy && <p role="status">{busy === "scan" ? "正在读取客机目录并运行 Mole 安全检查，最多约 100 秒。" : "正在逐项复查并移入客机废纸篓…"}</p>}
    {error && <p className="space-error" role="alert">{error}</p>}
    {plan?.warnings.map((warning, index) => <p className="space-warning" key={index}>{warning}</p>)}
    {results && <div className="space-results" role="status"><strong>已移入废纸篓 {results.filter(item => item.trashed).length} 项</strong>{results.filter(item => !item.trashed).map(item => <p key={item.id}>{item.name}：{item.error}</p>)}<p>可在客机废纸篓恢复。重新扫描以查看最新空间。</p></div>}
    {plan && <>
      <div className="space-list-header"><h2>扫描清单</h2><span>{new Date(plan.created_at).toLocaleTimeString()} · 清单 30 分钟有效</span></div>
      {plan.items.length === 0 ? <p>当前范围内没有可列出的缓存或日志。</p> : <ul className="space-list">{plan.items.map(item => <li key={item.id} className={item.blocked ? "protected" : ""}>
        <label><input type="checkbox" disabled={!!busy || consumed || !!item.blocked || item.bytes === 0} checked={selected.includes(item.id)} onChange={event => setSelected(ids => event.target.checked ? [...ids, item.id] : ids.filter(id => id !== item.id))} /><span><strong>{item.name}</strong><small>{item.category} · {item.path}</small>{item.blocked && <small className="space-warning">{item.blocked}</small>}</span><span className="space-size">{item.blocked ? "保留" : bytes(item.bytes)}</span></label>
      </li>)}</ul>}
      <div className="space-review"><span>已选 {selected.length} 项 · {bytes(selectedBytes)}</span><button className="primary" disabled={!!busy || !ready || consumed || selected.length === 0} onClick={clean}>审阅并移入废纸篓</button></div>
      <p className="space-footnote">{plan.engine}。仅在当前客机内运行；不读取主机目录，不自动清空废纸篓。</p>
    </>}
  </section>;
}
