import React, { useEffect, useRef, useState } from "react";
import { Activity, Globe2, LoaderCircle, Play, RefreshCw, ShieldCheck, Square } from "lucide-react";
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
const siteRounds = 8;
const siteLegend = [["fast", "优", "0–99 ms"], ["mid", "良", "100–399 ms"], ["slow", "慢", "≥ 400 ms"], ["failed", "超时 / 不可达", "未完成 HTTPS 探测"]];
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
    async function probe(key, retryConflict = false) {
      const send = () => api("/proxy/vmac-probe", { key, lease }, "POST", {}, { signal });
      try {
        return await send();
      } catch (error) {
        if (!retryConflict || error.status !== 409 || signal.aborted) throw error;
        const latest = await api("/proxy/vmac-protection", undefined, undefined, {}, { signal });
        if (latest.state !== "protected" || latest.lease !== lease || signal.aborted) throw error;
        return send();
      }
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

function latencyTone(ms) {
  if (ms === null) return "failed";
  if (ms < 100) return "fast";
  return ms < 400 ? "mid" : "slow";
}

export function SiteChecks({ protection }) {
  const session = useCheckRun(protection);
  const { run, current } = session;
  const [targets, setTargets] = useState([]);
  const [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    api("/proxy/vmac-targets",undefined,undefined,{}, {signal:controller.signal})
      .then(setTargets).catch(failure=>{ if (!controller.signal.aborted) setError(failure.message); });
    return ()=>controller.abort();
  },[]);
  function measure(group) {
    const list = targets.filter(target => !group || target.group === group);
    const samples = { ...(group && current ? run.samples : {}) };
    for (const { id } of list) delete samples[id];
    return session.begin(list, async ({ id }, probe, sample, signal) => {
      await probe(id, true);
      for (let index = 0; index < siteRounds && !signal.aborted; index++) {
        const start = performance.now();
        sample(id, await probe(id, true));
        if (index + 1 < siteRounds && !signal.aborted) {
          const delay = Math.max(0, 90 - (performance.now() - start)) + Math.random() * 140;
          await new Promise(resolve => setTimeout(resolve, delay));
        }
      }
    }, list.length * siteRounds, { samples, group });
  }
  const disabled = !protection.lease || !targets.length || run?.running;
  return <section className="vm-card vm-check">
    <div className="vm-card-head">
      <div><h2>网络连通测试</h2><p>从 macOS 客机经当前代理网关发出 HTTPS 探测。每站测 8 轮，显示成功样本的中位延迟。</p></div>
    </div>
    <div className="vm-actions">
      <button className="primary" disabled={disabled} onClick={() => measure(null)}>
        {run?.running ? <LoaderCircle size={14} className="spin" /> : <RefreshCw size={14} />}
        {run?.running ? "测试中…" : run ? "重新测试全部" : "测试全部"}
      </button>
      {run?.running && <button onClick={session.stop}><Square size={13} />停止测试</button>}
    </div>
    <Progress state={session} protection={protection} />
    {error && <p className="vm-error" role="alert">{error}</p>}
    <ul className="vm-site-legend" aria-label="延迟图例">{siteLegend.map(([tone, label, description]) =>
      <li key={tone} title={description}><i className={`vm-site-dot ${tone}`} aria-hidden="true" />{label}</li>)}</ul>
    <div className="vm-site-groups">
      {groups.map(([key, name]) => {
        const sites = targets.filter(target => target.group === key).map(target => {
          const samples = run?.samples[target.id] || [];
          return { ...target, samples, latency: median(samples) };
        });
        if (!sites.length) return null;
        const reachable = sites.flatMap(site => site.latency === null ? [] : [site.latency]);
        const measured = sites.some(site => site.samples.length);
        const average = reachable.length ? Math.round(reachable.reduce((sum, value) => sum + value, 0) / reachable.length) : null;
        const testing = run?.running && (!run.group || run.group === key);
        return <section className="vm-site-group" key={key} aria-labelledby={`vm-site-${key}`}>
          <header>
            <Globe2 size={16} aria-hidden="true" />
            <h3 id={`vm-site-${key}`}>{name}</h3>
            <small>{measured ? `${reachable.length} / ${sites.length} 可达` : `${sites.length} 站 · ${testing ? "测试中" : "未测"}`}{average !== null && ` · 平均 ${average} ms`}</small>
            <button className="vm-quiet" aria-label={`测试${name}站点`} disabled={disabled} onClick={() => measure(key)}><RefreshCw size={13} />测试此组</button>
          </header>
          <ul className="vm-site-grid">{sites.map(({ id, name, latency, samples }) => {
            const unreachable = latency === null && samples.length === siteRounds;
            return <li key={id}>
              <div className="vm-site-name"><strong>{name}</strong>
                <div className="vm-site-rounds" aria-label={`成功 ${samples.filter(sample => sample.ok).length} 轮，共 ${samples.length} 轮已测`}>
                  {Array.from({ length: siteRounds }, (_, index) => {
                    const sample = samples[index];
                    const reading = sample?.ok ? sample.ms : null;
                    const tooltip = sample ? sample.ok ? `${reading} ms · HTTP ${sample.status}` : sample.error : "未测";
                    return <i className={`vm-site-dot ${sample ? latencyTone(reading) : ""}`} key={index} title={`第 ${index + 1} 轮 · ${tooltip}`} />;
                  })}
                </div>
              </div>
              <span className={`vm-latency ${latency !== null || unreachable ? latencyTone(latency) : ""}`}>
                {latency !== null ? `${latency} ms` : unreachable ? "不可达" : testing ? "测试中" : samples.length ? "待完成" : "未测"}
              </span>
            </li>;
          })}</ul>
        </section>;
      })}
    </div>
    <p className="vm-note">单次探测上限 2.5 秒。收到 HTTP 响应即计为可达，延迟按收到首字节计算。</p>
  </section>;
}

export function ChecksPage({ status, protection, tab, onTabChange, onConfirm, onSettings, onInstall }) {
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
      : <SafetyPanel inline status={status} onConfirm={onConfirm} onSettings={onSettings} />}</div>
    <div className="vm-tabpanel" hidden={tab !== "gateway"}><NetworkChecks protection={protection} /></div>
    <div className="vm-tabpanel" hidden={tab !== "claude"}><ClaudeChecks protection={protection} /></div>
    <div className="vm-tabpanel" hidden={tab !== "sites"}><SiteChecks protection={protection} /></div>
  </div>;
}
