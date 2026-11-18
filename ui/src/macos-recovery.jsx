import React, { useState } from "react";
import { api } from "./api";

export async function requestMacOSRecovery(action, onConfirm, running = true) {
  const restart = action === "restart";
  const title = restart ? running ? "重启 macOS 客机？" : "启动 macOS 客机？" : "同步环境组件？";
  const body = restart
    ? "请先保存客机里的工作。重启会结束当前终端会话，客机文件和登录资料会保留。"
    : "请先保存工作。组件更新会重新连接浏览器和显示组件。";
  const confirm = restart ? running ? "重启客机" : "启动客机" : "同步组件";
  if (!(await onConfirm({ title, body, confirm }))) return null;
  return api(restart ? "/macos/restart" : "/environment/update", {});
}

export function MacOSRecoveryButton({ action = "restart", onConfirm, disabled, running = true }) {
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState("");
  const [failed, setFailed] = useState(false);
  if (!onConfirm) return null;
  const restart = action === "restart";
  const label = restart ? running ? "重启 macOS 客机" : "启动 macOS 客机" : "同步环境组件";
  async function run() {
    setPending(true);
    setMessage("");
    setFailed(false);
    try {
      const result = await requestMacOSRecovery(action, onConfirm, running);
      if (result) setMessage(`${label}已提交，进度见工作台。`);
    } catch (error) {
      setFailed(true);
      setMessage(error.message);
    } finally {
      setPending(false);
    }
  }
  return <>
    <button type="button" disabled={disabled || pending} onClick={run}>{label}</button>
    {message && <small role={failed ? "alert" : "status"}>{message}</small>}
  </>;
}
