import React, { useState } from "react";
import { Minus, Plus } from "lucide-react";

import { useAppearance } from "./appearance";
import { Group, Row, Toggle } from "./vmac-ui";
import { autoStartEnabled, setAutoStart } from "./vmac-shell.mjs";

const textSizes = { min: 12, max: 20 };

export function GeneralPage() {
  const [autoStart, setAutoStartState] = useState(() => autoStartEnabled(localStorage));
  const { appearance, loading, error, update, retry } = useAppearance();
  const patch = delta => update(previous => ({ ...previous, ...delta }));
  function changeAutoStart(value) {
    setAutoStart(localStorage, value);
    setAutoStartState(autoStartEnabled(localStorage));
  }
  const size = appearance.uiFontSize;
  return <>
    <Group title="启动">
      <Row title="打开 VMac 时自动启动客机" detail="关闭后，需要在概览里手动启动">
        <Toggle label="打开 VMac 时自动启动客机" checked={autoStart} onChange={changeAutoStart} />
      </Row>
    </Group>
    {/* VMac has one fixed look, so the display settings are the few that do
        not touch the palette. Each change is saved as it is made. */}
    <Group title="显示">
      <Row title="文字大小" detail="控制中心里所有页面的文字">
        <div className="vm-stepper" role="group" aria-label="文字大小">
          <button type="button" aria-label="减小文字" disabled={loading || size <= textSizes.min} onClick={() => patch({ uiFontSize: size - 1 })}><Minus size={14} /></button>
          <output aria-live="polite">{size}</output>
          <button type="button" aria-label="增大文字" disabled={loading || size >= textSizes.max} onClick={() => patch({ uiFontSize: size + 1 })}><Plus size={14} /></button>
        </div>
      </Row>
      <Row title="使用指针光标" detail="悬停在按钮上时显示手形">
        <Toggle label="使用指针光标" checked={appearance.pointerCursors} disabled={loading} onChange={pointerCursors => patch({ pointerCursors })} />
      </Row>
      <Row title="字体平滑">
        <Toggle label="字体平滑" checked={appearance.fontSmoothing} disabled={loading} onChange={fontSmoothing => patch({ fontSmoothing })} />
      </Row>
      <Row title="减少动态效果" detail="开启后只保留淡入淡出">
        <select className="vm-select" aria-label="减少动态效果" value={appearance.reducedMotion} disabled={loading}
          onChange={event => patch({ reducedMotion: event.target.value })}>
          <option value="system">跟随系统</option>
          <option value="on">开启</option>
          <option value="off">关闭</option>
        </select>
      </Row>
    </Group>
    {error && <p className="vm-group-note" role="alert">这些设置没能保存：{error} <button className="text-button" onClick={retry}>重试</button></p>}
  </>;
}
