// Run in the guest. Use the same signed window owner and one-use local
// callback as the existing browser audit, so this samples ordinary Chrome.
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.argv[1];
const { browserCallback, windowRequest } = await import(pathToFileURL(join(root, "controller/macos-browser-window.mjs")));
const socket = join(homedir(), "Library", "Caches", "dev.cage.GuestClaudeWindow", "window.sock");
const signal = AbortSignal.timeout(14000);

function collectSignals() {
  const time = Intl.DateTimeFormat().resolvedOptions();
  const languages = [...(navigator.languages || [navigator.language])].filter(Boolean);
  const sc = /^(zh-cn|zh-hans|zh$)/, tc = /^(zh-tw|zh-hk|zh-mo|zh-hant)/;
  const cnZones = ["Asia/Shanghai","Asia/Urumqi","Asia/Chongqing","Asia/Chungking","Asia/Harbin","Asia/Kashgar"];
  const fontsSC = ["Microsoft YaHei","SimSun","SimHei","KaiTi","FangSong","DengXian","PingFang SC","Hiragino Sans GB","STHeiti","STSong","Songti SC","Source Han Sans CN","Noto Sans CJK SC","WenQuanYi Micro Hei"];
  const fontsTC = ["Microsoft JhengHei","PMingLiU","MingLiU","PingFang TC","PingFang HK","Noto Sans CJK TC"];
  const context = document.createElement("canvas").getContext("2d");
  const text = "mmmmmmmmmmlliWW汉字测试";
  const available = font => ["monospace","sans-serif","serif"].some(base => {
    context.font = "72px "+base;
    const before = context.measureText(text).width;
    context.font = `72px "${font}",${base}`;
    return Math.abs(context.measureText(text).width-before) > .5;
  });
  const foundSC = context ? fontsSC.filter(available) : [];
  const foundTC = context ? fontsTC.filter(available) : [];
  const lower = languages.map(s => s.toLowerCase());
  const offset = new Date().getTimezoneOffset();
  const ua = navigator.userAgent;
  const family = /Mac|iPhone|iPad/.test(ua) ? "Apple 平台" : /Windows/.test(ua) ? "Windows" : /Android/.test(ua) ? "Android" : "其他平台";
  const rows = [
    ["系统时区", 30, time.timeZone, cnZones.includes(time.timeZone) ? 1 : ["Asia/Hong_Kong","Asia/Macau","Asia/Taipei"].includes(time.timeZone) ? .6 : 0],
    ["浏览器语言", 24, languages.join(", "), sc.test(lower[0] || "") ? 1 : tc.test(lower[0] || "") ? .5 : lower.some(x=>sc.test(x)) ? .7 : lower.some(x=>x.startsWith("zh")) ? .4 : 0],
    ["可用中文字体", 20, context ? [...foundSC,...foundTC].join(" · ") || "未探测到列表中的字体" : null, foundSC.length ? Math.min(1,.75+.08*foundSC.length) : foundTC.length ? .5 : 0],
    ["Intl 区域设置", 10, time.locale, sc.test((time.locale || "").toLowerCase()) ? 1 : (time.locale || "").toLowerCase().startsWith("zh") ? .5 : 0],
    ["时区偏移", 8, Number.isFinite(offset) ? `UTC${offset <= 0 ? "+" : "−"}${Math.abs(offset/60)} · ${offset} 分钟` : null, offset === -480 ? .7 : 0],
    ["渲染家族", 8, ua ? family + " · 按浏览器 UA 归类" : null, 0],
  ].map(([title,weight,value,ratio])=>({title,weight,value:value || null,points:value ? Math.round(weight*ratio) : null}));
  return {rows, webrtc:typeof RTCPeerConnection === "function"};
}

const stop = await windowRequest(socket,"status",{},signal);
if (stop.login) throw new Error("Chrome login is active");
const callback = await browserCallback("127.0.0.1",(url,res)=>{
  const data = JSON.parse(url.searchParams.get("result"));
  res.setHeader("Content-Type","text/html; charset=utf-8");
  res.end("<!doctype html><meta charset=utf-8><title>VMac 浏览器检测完成</title><p>检测完成，可以关闭此标签页。</p><script>window.close()</script>");
  return data;
});
let view;
const cancel = () => {callback.close();view?.close();};
signal.addEventListener("abort",cancel,{once:true});
try {
  view = await browserCallback("127.0.0.1",(_,res)=>{
    res.setHeader("Content-Type","text/html; charset=utf-8");
    res.end(`<!doctype html><meta charset=utf-8><title>VMac 正在检测浏览器环境</title><script>
    const target=new URL(${JSON.stringify(callback.url)});
    target.searchParams.set("result",JSON.stringify((${collectSignals.toString()})()));
    location.replace(target.href);
    </script>`);
  });
  await windowRequest(socket,"launch",{url:view.url},signal);
  console.log(JSON.stringify(await callback.result));
} finally {
  signal.removeEventListener("abort",cancel);
  cancel();
}
