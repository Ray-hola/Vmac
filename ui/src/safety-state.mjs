export function isSafetyCheckMessage(message) {
  return typeof message === "string" && /关键(?:检查|检测)(?:尚未|未|失败|证据不完整)|完成关键检查|外网(?:未放行|保持关闭)|浏览器配置检查未通过/.test(message);
}

export function macOSNetworkRestartMessage(status) {
  if (status?.guest_system !== "macos" || status.job?.running) return "";
  if (["safety", "start", "restart", "network-recovery", "settings"].includes(status.job?.kind) && status.job.recovery === "environment-restart") {
    return status.job.error || "";
  }
  const restartMessages = [
    "网络设置已保存，请重启 macOS 客机，登录后重新检测",
    "出口地址或环境设置变化需要重启环境",
    "已保存固定出口。请重启 macOS 客机，登录后重新检测。",
  ];
  return [status.job?.error, status.safety?.error, status.network_error]
    .find(message => restartMessages.includes(message)) || "";
}

export function networkState(status, now = Date.now()) {
  if (!status?.vm_running) return { mode: "stopped", label: "环境已停止" };
  const gate = status.safety?.gate;
  if (!gate) return { mode: "unknown", label: "外网状态待确认" };
  const until = Date.parse(gate.until);
  if (gate.mode === "open" && Number.isFinite(until) && until > now)
    return { mode: "open", label: "外网已放行" };
  if (gate.mode === "checking" && Number.isFinite(until) && until > now)
    return { mode: "checking", label: "正在检查" };
  if (gate.mode === "closed" || (Number.isFinite(until) && until <= now))
    return { mode: "closed", label: "外网已关闭" };
  return { mode: "unknown", label: "外网状态待确认" };
}

export function isolationSummary(status, now = Date.now()) {
  const { gate, report } = status?.safety || {};
  const checks = report?.checks?.filter(check => check.critical) || [];
  const current = Boolean(report?.id && gate?.report?.id === report.id &&
    report.run_id === gate.run_id && report.configuration === gate.configuration &&
    networkState(status, now).mode === "open");
  return {
    current,
    passed: checks.filter(check => check.state === "passed").length,
    total: checks.length,
  };
}

export function canonicalExitPolicy(value = {}) {
  return {
    mode: value.mode || "dynamic",
    scope: value.scope || "country",
    ip: (value.ip || "").trim(),
    country_code: (value.country_code || "").trim().toUpperCase(),
    region: (value.region || "").trim().replace(/\s+/g, " "),
    city: (value.city || "").trim().replace(/\s+/g, " "),
  };
}

export function reportForSharing(report) {
  return {
    policy: report.policy,
    created_at: report.created_at,
    checks: report.checks,
    scope: "采样与运行时策略检查；不代表平台账号资格或完整虚拟化审计",
  };
}

export function isGuestLocalURL(value) {
  if (value === "about:blank") return true;
  try {
    const url = new URL(value);
    return (
      ["http:", "https:"].includes(url.protocol) &&
      ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
    );
  } catch {
    return false;
  }
}
