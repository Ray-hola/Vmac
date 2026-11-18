import React, { useEffect, useRef, useState } from "react";
import { api } from "./api";

const protectionLabel = {
  protected: "受保护", checking: "检查中", paused: "手动断网", unready: "未就绪", expired: "结果过期",
};
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

export function NetworkChecks({ protection, onEnvironment }) {
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
  return <section className="vmac-section vmac-network" aria-label="网关检测">
    <div className="vmac-check-head">
      <h2>网关检测</h2>
      <span className={protection.lease ? "vmac-ok" : "vmac-muted"}>{protectionLabel[protection.state] || "正在读取"}</span>
    </div>
    <p>{protection.reason || "正在读取当前客机门禁和 Mihomo 核心…"}</p>
    <div className="vmac-form-row">
      <button disabled={pending} onClick={run}>{pending ? "检测中…" : "代理检测"}</button>
      <button onClick={onEnvironment}>环境检测</button>
    </div>
    {measured?.observed_at && <p role="status" className={current ? "vmac-reading" : ""}>
      TCP {measured.tcp ? "通过" : "未通过"} · UDP {measured.udp ? "通过" : "未通过"} · {stamp(measured.observed_at)}
      {!current && " · 历史结果"}
    </p>}
    {measured && !measured.observed_at && <p role="status">TCP、UDP 未验证。{measured.stale ? "检测期间出口或门禁发生变化。" : measured.protection?.reason}</p>}
    {error && <p role="alert">{error}</p>}
    {!!protection.checks?.length && <details className="vmac-check-details">
      <summary>查看保护依据</summary>
      {protection.report_at && <p>隔离报告 {stamp(protection.report_at)}{protection.until && ` · 有效至 ${stamp(protection.until)}`}</p>}
      <dl>{protection.checks.map(check => <React.Fragment key={check.label}>
        <dt>{check.label} <small>{checkLabel[check.state] || check.state}</small></dt>
        <dd>{check.detail}</dd>
      </React.Fragment>)}</dl>
    </details>}
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
    {!protection.lease && <p className="vmac-muted">已暂停外部探测。{protection.reason || "当前客机保护未放行。"}</p>}
    {run && <div className="vmac-progress" role="status">
      <progress max={run.total} value={run.done} aria-label="检测进度" />
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
  return <section className="vmac-section">
    <h2>Claude 检测</h2>
    <p>站点和解析器探测经当前客机网关发出。环境项通过客机 Chrome 里的本地检测页采集。</p>
    <div className="vmac-form-row">
      <button className="primary" disabled={!protection.lease || run?.running} onClick={runTests}>开始检测</button>
      {run?.running && <button onClick={session.stop}>停止检测</button>}
    </div>
    <Progress state={session} protection={protection} />
    <div className="vmac-trace-grid">
      {[["claude-com","claude.com"],["claude-ai","claude.ai"]].map(([key,host])=>{
        const item = samples[key]?.[0];
        return <div key={key} className="vmac-check-card">
          <strong>{host}</strong>
          <p className="vmac-reading">{item?.ip || (item ? "未取得出口" : "未测")}</p>
          {item?.ip ? <p>{item.loc || "地区未知"} · {item.colo || "边缘节点未知"} · {item.ms} ms</p> : item && <p>{item.error}</p>}
        </div>;
      })}
    </div>
    <h3>DNS 解析器</h3>
    <p>有效响应 {valid} / {received} · {dns.size} 组解析器</p>
    {!dns.size ? <p>{received ? "本次未取得有效解析器样本。" : "未测"}</p> : <ul className="vmac-profiles">
      {[...dns.values()].map(row=><li className="vmac-row" key={row.ip}>
        <div><strong>{row.ip}</strong><small>{[row.geo,row.org,[...row.sources].join(" / ")].filter(Boolean).join(" · ")}</small></div>
        <span>{row.cc || "归属未知"}</span>
      </li>)}
    </ul>}
    <h3>客机浏览器区域信号</h3>
    <p>{score === null ? "分数暂不可用" : `${score} / 100 · ${score <= 30 ? "较少区域特征" : score <= 60 ? "中等区域特征" : "较多区域特征"}`}。分数仅描述当前检测页的区域信号，无法判断 Claude 账号状态或网络泄露情况。</p>
    {browser?.error && <p>{browser.error}</p>}
    <ul className="vmac-profiles">{rows.map(row=><li className="vmac-row" key={row.title}>
      <div><strong>{row.title}</strong><small>{row.value || "未测"}</small></div>
      <span>{row.points === null ? "未测" : `${row.points} / ${row.weight}`}</span>
    </li>)}</ul>
    <p>WebRTC {browser?.webrtc === true ? "API 可用" : browser?.webrtc === false ? "API 不可用" : "未测"} · STUN 未测。</p>
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
  return <section className="vmac-section">
    <h2>网络连通测试</h2>
    <p>测量 HTTPS 请求总耗时。401、404 等响应计为站点可达，业务可用性未测。</p>
    <div className="vmac-form-row">
      <button className="primary" disabled={disabled} onClick={()=>measure(null)}>开始检测</button>
      <select aria-label="测试轮数" value={rounds} onChange={event=>setRounds(Number(event.target.value))} disabled={session.run?.running}>
        <option value={1}>快速检测 · 1 轮</option><option value={8}>完整检测 · 8 轮</option>
      </select>
      {session.run?.running && <button onClick={session.stop}>停止检测</button>}
    </div>
    <Progress state={session} protection={protection} />
    {error && <p role="alert">{error}</p>}
    {groups.map(([key,name])=>{
      const items = targets.filter(target=>target.group===key);
      const reachable = items.filter(item=>median(session.run?.samples[item.id]||[])!==null).length;
      return <details className="vmac-check-details" key={key} open={session.run?.done > 0 || undefined}>
        <summary>{name} <small>{items.length ? `${reachable} / ${items.length} 可达` : "正在读取站点"}</small></summary>
        <div className="vmac-form-row"><button disabled={disabled} onClick={()=>measure(key)}>检测{name}站点</button></div>
        <ul className="vmac-profiles">{items.map(item=>{
          const results = session.run?.samples[item.id] || [];
          const latency = median(results);
          const successes = results.filter(value=>value.ok);
          return <li className="vmac-row" key={item.id}>
            <div><strong>{item.name}</strong><small>{results.length ? `成功 ${successes.length} / ${results.length} · ${successes.length ? "HTTP "+[...new Set(successes.map(value=>value.status))].join(" / ") : "未收到 HTTPS 响应"}` : "未测"}</small></div>
            <span className="vmac-reading">{latency === null ? "—" : `${latency} ms`}</span>
          </li>;
        })}</ul>
      </details>;
    })}
  </section>;
}
