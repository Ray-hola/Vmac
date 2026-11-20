import React, { useState } from "react";

import { Group, Row, Toggle } from "./vmac-ui";
import { autoStartEnabled, setAutoStart } from "./vmac-shell.mjs";

export function GeneralPage() {
  const [autoStart, setAutoStartState] = useState(() => autoStartEnabled(localStorage));
  function change(value) {
    setAutoStart(localStorage, value);
    setAutoStartState(autoStartEnabled(localStorage));
  }
  return <Group title="启动">
    <Row title="打开 VMac 时自动启动客机" detail="关闭后，需要在概览里手动启动">
      <Toggle label="打开 VMac 时自动启动客机" checked={autoStart} onChange={change} />
    </Row>
  </Group>;
}
