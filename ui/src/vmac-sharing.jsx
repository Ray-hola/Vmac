import React, { useEffect, useState } from "react";

import { native } from "./api";
import { Group, Row, Toggle } from "./vmac-ui";

const switches = [
  ["shareClipboardContent", "共享剪贴板", "文字、图片和文件在 Mac 和客机之间双向同步"],
  ["fileDrop", "拖放文件", "把文件拖进客机画面，或从客机拖到 Mac"],
  ["hostInputMethod", "用 Mac 输入法在客机中打字", "客机里请切换到英文（ABC）输入"],
];

// The switches are stored by the app itself, so the File menu and this page
// always show the same state.
export function SharingPage() {
  const [values, setValues] = useState(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    const load = () => native("vmacPreferences")
      .then(next => { if (live) { setValues(next); setError(""); } })
      .catch(failure => { if (live) setError(failure.message); });
    load();
    window.addEventListener("vmac-preferences-changed", load);
    return () => { live = false; window.removeEventListener("vmac-preferences-changed", load); };
  }, []);
  async function change(key, value) {
    setValues(current => ({ ...current, [key]: value }));
    try {
      setValues(await native("vmacSetPreference", { key, value }));
      setError("");
    } catch (failure) {
      setValues(current => ({ ...current, [key]: !value }));
      setError(failure.message);
    }
  }
  return <>
    <Group label="共享">
      {switches.map(([key, title, detail]) => <Row key={key} title={title} detail={detail}>
        <Toggle label={title} checked={values?.[key] ?? true} disabled={!values} onChange={value => change(key, value)} />
      </Row>)}
    </Group>
    {error && <p className="vm-group-note" role="alert">没能读取或保存这些设置：{error}</p>}
  </>;
}
