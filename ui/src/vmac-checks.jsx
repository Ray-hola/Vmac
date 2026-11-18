import React, { useEffect, useRef, useState } from "react";
import { Activity, Globe2, LoaderCircle, Play, ShieldCheck, Square } from "lucide-react";
import { api } from "./api";
import { SafetyPanel } from "./safety";
import { isolationSummary } from "./safety-state.mjs";
import { Segmented, StatusChip } from "./vmac-ui";

const protectionLabel = {
  protected: "受保护", checking: "检查中", paused: "手动断网", unready: "未就绪", expired: "结果过期",
};
export const protectionTone = { protected: "ok", checking: "busy", paused: "warn", unready: "idle", expired: "warn" };
export const protectionText = state => protectionLabel[state?.state] || "正在读取";
const checkLabel = { passed: "通过", failed: "未通过", unknown: "待验证", stale: "过期", blocked: "已断网" };
const groups = [["cn","中国"],["jp","日本"],["us","美国"],["gl","全球"]];
const dnsKeys = [
  ...Array(5).fill("dns-surfshark"), ...Array(5).fill("dns-fastly"),
  ...Array(3).fill("dns-v4"), ...Array(3).fill("dns-v6"),
];
const stamp = value => new Date(value).toLocaleString();

export function useVMacProtection(active, gate) {
  const [state, setState] = useState(null);
  const read = useRef(null);
  useEffect(() => {
    if (!active) return;
    const request = new AbortController();
    let timer;
    let running = false;
    async function poll() {
      if (running || request.signal.aborted) return;
      clearTimeout(timer);
      running = true;
      try {
        const value = await api("/proxy/vmac-protection", undefined, undefined, {}, { signal: request.signal });
        if (!request.signal.aborted) setState(value);
      } catch (error) {
        if (!request.signal.aborted) setState({ state: "unready", reason: error.message, checks: [] });
      } finally {
        running = false;
        if (!request.signal.aborted) timer = setTimeout(poll, 3500);
      }
    }
    read.current = poll;
    poll();
    return () => { request.abort(); clearTimeout(timer); read.current = null; };
  }, [active, gate?.mode, gate?.epoch, gate?.run_id]);
  // A newer environment poll can retract permission before protection refreshes.
  const protectedNow = gate?.mode === "open" && state?.state === "protected"
    && state.run_id === gate.run_id && state.epoch === gate.epoch
    && state.until && Date.parse(state.until) > Date.now();
  const stale = state?.state === "protected" && !protectedNow;
  const transition = stale ? {
    state: gate?.mode === "checking" ? "checking" : state.until && Date.parse(state.until) <= Date.now() ? "expired" : "unready",
    reason: gate?.reason || "客机门禁已变化，正在刷新保护状态。",
  } : {};
  return { ...state, ...transition, lease: protectedNow ? state.lease : "", refresh: () => read.current?.() };
}

export function NetworkChecks({ protection }) {
  const [pending, setPending] = useState(false);
  const [measured, setMeasured] = useState(null);
  const [error, setError] = useState("");
  const current = protection.lease && measured?.protection?.lease === protection.lease;
  async function run() {
    setPending(true);
    setError("");
    try {
      setMeasured(await api("/proxy/vmac-check", {}));
      protection.refresh();
    } catch (failure) { setError(failure.message); }
    finally { setPending(false); }
  }
  return <section className="vm-card vm-check" aria-label="网关检测">
    <div className="vm-card-head">
      <div><h2>网关检测</h2><p>{protection.reason || "正在读取当前客机门禁和 Mihomo 核心…"}</p></div>
      <StatusChip tone={protectionTone[protection.state] || "idle"}>{protectionText(protection)}</StatusChip>
    </div>
    <div className="vm-actions">
      <button className="primary" disabled={pending} onClick={run}>{pending ? <LoaderCircle size={15} className="spin" /> : <Activity size={15} />}{pending ? "检测中…" : "检测 TCP / UDP"}</button>
    </div>
    {measured?.observed_at && <div className={`vm-result-row ${current ? "" : "stale"}`} role="status">
      <span className={measured.tcp ? "ok" : "bad"}>TCP {measured.tcp ? "通过" : "未通过"}</span>
      <span className={measured.udp ? "ok" : "bad"}>UDP {measured.udp ? "通过" : "未通过"}</span>
      <small>{stamp(measured.observed_at)}{!current && " · 历史结果"}</small>
    </div>}
    {measured && !measured.observed_at && <p role="status">TCP、UDP 未验证。{measured.stale ? "检测期间出口或门禁发生变化。" : measured.protection?.reason}</p>}
    {error && <p className="vm-error" role="alert">{error}</p>}
    {!!protection.checks?.length && <div className="vm-evidence">
      <h3>保护依据{protection.report_at && <small>隔离报告 {stamp(protection.report_at)}{protection.until && ` · 有效至 ${stamp(protection.until)}`}</small>}</h3>
      <ul>{protection.checks.map(check => <li key={check.label} className={check.state}>
        <i aria-hidden="true" /><strong>{check.label}</strong><span>{check.detail}</span><small>{checkLabel[check.state] || check.state}</small>
      </li>)}</ul>
    </div>}
  </section>;
}

function useCheckRun(protection) {
  const [run, setRun] = useState(null);
  const owned = useRef(null);
  useEffect(() => () => owned.current?.abort(), []);
  useEffect(() => {
    if (run?.running && run.lease !== protection.lease) {
      owned.current?.abort();
      setRun(previous => ({ ...previous, running: false, note: "当前客机、出口或门禁已变化，检测已暂停。" }));
    }
  }, [protection.lease, run?.lease, run?.running]);
  function stop() {
    owned.current?.abort();
    setRun(previous => previous ? { ...previous, running: false, note: "检测已停止，已返回的样本保留。" } : null);
  }
  async function begin(tasks, execute, total, initial = {}) {
    if (!protection.lease || run?.running || !tasks.length) return;
    const previous = owned.current;
    previous?.abort();
    const request = new AbortController();
    owned.current = request;
    const { signal } = request;
    const lease = protection.lease;
    const update = effect => {
      if (!signal.aborted && owned.current === request) setRun(current => current?.request === request ? effect(current) : current);
    };
    setRun({ request, lease, started: Date.now(), running: true, total, done: 0, samples: {}, ...initial });
    let next = 0;
    let paused = false;
    let message = "";
    async function probe(key) {
      return api("/proxy/vmac-probe", { key, lease }, "POST", {}, { signal });
    }
    function sample(id, result) {
      update(state => ({
        ...state, done: state.done + 1,
        samples: { ...state.samples, [id]: [...(state.samples[id] || []), result] },
      }));
    }
    async function worker() {
      while (!signal.aborted && next < tasks.length) {
        const item = tasks[next++];
        try { await execute(item, probe, sample, signal); }
        catch (error) {
          if (signal.aborted) return;
          paused = true;
          message = error.message;
          update(state => ({ ...state, running: false, note: message, obsolete: true }));
          request.abort();
        }
      }
    }
    await Promise.all(Array.from({ length: Math.min(6, tasks.length) }, worker));
    if (!paused) update(state => ({ ...state, running: false, note: "检测完成" }));
  }
  return {run, begin, stop, current: Boolean(protection.lease && run?.lease === protection.lease && !run.obsolete)};
}

function Progress({ state, protection }) {
  const { run, current } = state;
  return <>
    {!protection.lease && <p className="vm-note">已暂停外部探测。{protection.reason || "当前客机保护未放行。"}</p>}
    {run && <div className={`vm-progress ${run.running ? "running" : ""}`} role="status">
      <div className="vm-progress-track" role="progressbar" aria-label="检测进度" aria-valuemax={run.total} aria-valuenow={run.done}>
        <i style={{ width: `${run.total ? run.done / run.total * 100 : 0}%` }} />
      </div>
      <span>{run.done} / {run.total} · {run.running ? "正在检测" : run.note} · {stamp(run.started)}{!current && " · 历史结果"}</span>
    </div>}
  </>;
}

export function ClaudeChecks({ protection }) {
  const session = useCheckRun(protection);
  const { run } = session;
  const samples = run?.samples || {};
  const dns = new Map();
  let valid = 0;
  let received = 0;
  for (const key of new Set(dnsKeys)) {
    for (const report of samples[key] || []) {
      received++;
      if (report.dns?.length) valid++;
      for (const row of report.dns || []) {
        const family = row.ip.includes(":") ? row.ip.split(":").filter(Boolean).slice(0,4).join(":") : row.ip.split(".").slice(0,3).join(".");
        if (dns.has(family)) dns.get(family).sources.add(row.source);
        else dns.set(family,{...row,sources:new Set([row.source])});
      }
    }
  }
  const browser = samples["browser-signals"]?.[0];
  const rows = browser?.rows || [
    ["系统时区",30],["浏览器语言",24],["可用中文字体",20],["Intl 区域设置",10],["时区偏移",8],["渲染家族",8],
  ].map(([title,weight])=>({title,weight,points:null,value:null}));
  const complete = rows.every(row=>Number.isInteger(row.points));
  const score = complete ? rows.reduce((sum,row)=>sum+row.points,0) : null;
  const runTests = () => {
    const keys = ["claude-com","claude-ai","browser-signals",...dnsKeys];
    return session.begin(keys, async (key,probe,sample) => sample(key,await probe(key)), keys.length);
  };
  return <section className="vm-card vm-check">
    <div className="vm-card-head">
      <div><h2>Claude 检测</h2><p>站点和解析器探测经当前客机网关发出。环境项通过客机 Chrome 里的本地检测页采集。</p></div>
    </div>
    <div className="vm-actions">
      <button className="primary" disabled={!protection.lease || run?.running} onClick={runTests}><Play size={14} fill="currentColor" />开始检测</button>
      {run?.running && <button onClick={session.stop}><Square size={13} />停止检测</button>}
    </div>
    <Progress state={session} protection={protection} />
    <div className="vm-trace-grid">
      {[["claude-com","claude.com"],["claude-ai","claude.ai"]].map(([key,host])=>{
        const item = samples[key]?.[0];
        return <div key={key} className={`vm-trace ${item?.ip ? "ok" : item ? "bad" : ""}`}>
          <small><Globe2 size={13} />{host}</small>
          <strong>{item?.ip || (item ? "未取得出口" : "未测")}</strong>
          {item?.ip ? <span>{item.loc || "地区未知"} · {item.colo || "边缘节点未知"} · {item.ms} ms</span> : item ? <span>{item.error}</span> : <span>等待检测</span>}
        </div>;
      })}
    </div>
    <div className="vm-subsection">
      <h3>DNS 解析器<small>有效响应 {valid} / {received} · {dns.size} 组解析器</small></h3>
      {!dns.size ? <p className="vm-note">{received ? "本次未取得有效解析器样本。" : "未测"}</p> : <ul className="vm-rows">
        {[...dns.values()].map(row=><li key={row.ip}>
          <div><strong>{row.ip}</strong><small>{[row.geo,row.org,[...row.sources].join(" / ")].filter(Boolean).join(" · ")}</small></div>
          <span>{row.cc || "归属未知"}</span>
        </li>)}
      </ul>}
    </div>
    <div className="vm-subsection">
      <h3>客机浏览器区域信号<small>{score === null ? "分数暂不可用" : `${score} / 100 · ${score <= 30 ? "较少区域特征" : score <= 60 ? "中等区域特征" : "较多区域特征"}`}</small></h3>
      <p className="vm-note">分数仅描述当前检测页的区域信号，无法判断 Claude 账号状态或网络泄露情况。</p>
      {browser?.error && <p className="vm-error">{browser.error}</p>}
      <ul className="vm-rows">{rows.map(row=><li key={row.title}>
        <div><strong>{row.title}</strong><small>{row.value || "未测"}</small></div>
        <span className="vm-score">{row.points === null ? "未测" : <><i style={{ width: `${row.points / row.weight * 100}%` }} /><b>{row.points} / {row.weight}</b></>}</span>
      </li>)}</ul>
      <p className="vm-note">WebRTC {browser?.webrtc === true ? "API 可用" : browser?.webrtc === false ? "API 不可用" : "未测"} · STUN 未测。</p>
    </div>
  </section>;
}

function median(result) {
  const values = result.filter(sample=>sample.ok).map(sample=>sample.ms).sort((a,b)=>a-b);
  if (!values.length) return null;
  const middle = Math.floor(values.length/2);
  return values.length % 2 ? values[middle] : Math.round((values[middle-1]+values[middle])/2);
}

export function SiteChecks({ protection }) {
  const session = useCheckRun(protection);
  const [targets,setTargets] = useState([]);
  const [rounds,setRounds] = useState(1);
  const [error,setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    api("/proxy/vmac-targets",undefined,undefined,{}, {signal:controller.signal})
      .then(setTargets).catch(failure=>{ if (!controller.signal.aborted) setError(failure.message); });
    return ()=>controller.abort();
  },[]);
  function measure(group) {
    const list = targets.filter(target=>!group || target.group===group);
    return session.begin(list, async (target,probe,sample,signal) => {
      if (rounds>1) await probe(target.id);
      for (let i=0;i<rounds && !signal.aborted;i++) {
        sample(target.id,await probe(target.id));
        if (i+1<rounds) await new Promise(resolve=>setTimeout(resolve,100));
      }
    }, list.length*rounds);
  }
  const disabled = !protection.lease || !targets.length || session.run?.running;
  return <section className="vm-card vm-check">
    <div className="vm-card-head">
      <div><h2>网络连通测试</h2><p>测量 HTTPS 请求总耗时。401、404 等响应计为站点可达，业务可用性未测。</p></div>
    </div>
    <div className="vm-actions">
      <button className="primary" disabled={disabled} onClick={()=>measure(null)}><Play size={14} fill="currentColor" />开始检测</button>
      <Segmented label="测试轮数" value={rounds} onChange={setRounds} disabled={session.run?.running}
        items={[[1, "快速 · 1 轮"], [8, "完整 · 8 轮"]]} />
      {session.run?.running && <button onClick={session.stop}><Square size={13} />停止检测</button>}
    </div>
    <Progress state={session} protection={protection} />
    {error && <p className="vm-error" role="alert">{error}</p>}
    <div className="vm-site-groups">
      {groups.map(([key,name])=>{
        const items = targets.filter(target=>target.group===key);
        const reachable = items.filter(item=>median(session.run?.samples[item.id]||[])!==null).length;
        return <details className="vm-site-group" key={key} open={session.run?.done > 0 || undefined}>
          <summary><strong>{name}</strong><small>{items.length ? `${reachable} / ${items.length} 可达` : "正在读取站点"}</small>
            <button className="vm-quiet" disabled={disabled} onClick={event=>{ event.preventDefault(); measure(key); }}>检测此组</button>
          </summary>
          <ul className="vm-rows">{items.map(item=>{
            const results = session.run?.samples[item.id] || [];
            const latency = median(results);
            const successes = results.filter(value=>value.ok);
            return <li key={item.id}>
              <div><strong>{item.name}</strong><small>{results.length ? `成功 ${successes.length} / ${results.length} · ${successes.length ? "HTTP "+[...new Set(successes.map(value=>value.status))].join(" / ") : "未收到 HTTPS 响应"}` : "未测"}</small></div>
              <span className={`vm-latency ${latency === null ? "" : latency < 300 ? "fast" : latency < 800 ? "mid" : "slow"}`}>{latency === null ? "—" : `${latency} ms`}</span>
            </li>;
          })}</ul>
        </details>;
      })}
    </div>
  </section>;
}

export function ChecksPage({ status, protection, tab, onTabChange, onConfirm, onSettings, onOpenPage, onInstall }) {
  const critical = isolationSummary(status);
  const location = status.location;
  const tiles = [
    { label: "网关保护", value: protectionText(protection), detail: protection.until ? `有效至 ${stamp(protection.until)}` : protection.reason || "正在读取", tone: protectionTone[protection.state] || "idle" },
    { label: "隔离检查", value: critical.total ? `${critical.current ? "" : "上次 · "}${critical.passed} / ${critical.total} 通过` : "尚无记录", detail: status.safety?.report?.created_at ? `检测于 ${stamp(status.safety.report.created_at)}` : "启动客机后自动检测", tone: critical.current && critical.total && critical.passed === critical.total ? "ok" : critical.total ? "warn" : "idle" },
    { label: protection.lease || !location?.ip ? "当前出口" : "上次检测出口", value: location?.ip || "未检测", detail: location ? [location.country, location.city].filter(Boolean).join(" ") || "地区未知" : "经当前代理节点查询", tone: location?.ip && protection.lease ? "ok" : "idle" },
  ];
  return <div className="vm-checks">
    <div className="vm-stats">
      {tiles.map(tile => <div key={tile.label} className={`vm-stat ${tile.tone}`}>
        <small><ShieldCheck size={13} />{tile.label}</small><strong>{tile.value}</strong><span>{tile.detail}</span>
      </div>)}
    </div>
    <Segmented label="检测类别" value={tab} onChange={onTabChange}
      items={[["isolation", "隔离报告"], ["gateway", "网关检测"], ["claude", "Claude 检测"], ["sites", "网络连通"]]} />
    {/* Panels stay mounted so a running probe batch survives switching tabs. */}
    <div className="vm-tabpanel" hidden={tab !== "isolation"}>{onInstall
      ? <section className="vm-card vm-empty"><h2>还没有安装 macOS</h2><p>安装并启动客机后，可以运行隔离检查。</p><button className="primary" onClick={onInstall}>打开安装向导</button></section>
      : <SafetyPanel inline status={status} onConfirm={onConfirm} onSettings={onSettings} onOpenPage={onOpenPage} />}</div>
    <div className="vm-tabpanel" hidden={tab !== "gateway"}><NetworkChecks protection={protection} /></div>
    <div className="vm-tabpanel" hidden={tab !== "claude"}><ClaudeChecks protection={protection} /></div>
    <div className="vm-tabpanel" hidden={tab !== "sites"}><SiteChecks protection={protection} /></div>
  </div>;
}
