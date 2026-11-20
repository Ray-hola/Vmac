# 界面第二期（上）：导航与页面合并 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把侧栏的九个入口和旧「设置」里的十个分组合并成一套十项导航，旧「设置」不再是单独的界面。

**Architecture:** 页面清单只定义一次（`ui/src/vmac-pages.mjs`：分组、标题、图标、旧入口到新页面的对应），原生侧栏持有一份副本，由测试保证一致。旧「设置」的各个分组不重写，而是让 `SettingsPanel` 支持「嵌入」方式，按页面把对应的分组直接显示在页面里，各自的保存逻辑保持原样。新增的「共享与传输」和「通用」里的开关用新的分组列表组件。

**Tech Stack:** React 和纯 CSS，Swift / AppKit，Objective-C，Node 自带测试。

**Spec:** `docs/superpowers/specs/2026-11-20-vmac-native-ui-redesign-design.md`（第 4.1、5、6.4、7.1 节），`docs/superpowers/specs/2026-11-20-vmac-native-experience-roadmap.md`（第 7 节的遗留清单）。

## Global Constraints

- 所有现有功能都保留，只改变位置和呈现。任何旧入口（侧栏项、「设置」分组、菜单项、页面里的跳转按钮）都必须能到达对应的新页面。
- VMac 只有浅色一套配色，颜色只用 `ui/src/vmac-tokens.mjs` 里的值。
- 动效时长只有 120、200、320 毫秒，曲线 `cubic-bezier(.2,.8,.2,1)`；「减弱动态效果」开启时只淡入淡出。
- 需要重启环境才生效的设置（加密 DNS、时区、语言、出口规则）保留现有的「保存并重启」流程，不改成即时生效。开关类的设置即时生效。
- 桌面状态下 VMac 只占用 `⌃⌘F` 和 `⌃⌘,`。
- 不引入新的界面框架或组件库。不改隔离、代理、检测的行为。
- 界面文字用中文；代码注释和提交说明用英文。
- 这一期不重排各页面内部的布局（代理、检测、磁盘等页面的内部结构不动），那是第二期（下）。

## Review Focus

1. 在某个设置分组里改了一半没保存，就切到别的页面：应先询问是否放弃修改，和旧「设置」切换分组时一样。由 Task 4 的 `leavingNeedsConfirm` 测试和人工核对覆盖。
2. 旧的跳转仍在用旧名字（`openSettings("region")`、原生菜单的「设置…」、检测页的「出口规则」、`cage-guest-settings` 事件）：都要落到正确的新页面。由 Task 1 的 `pageFor` 测试覆盖。
3. 从「文件」菜单切换共享剪贴板，页面上的开关要同步变化；反过来也一样。由 Task 6 的人工核对覆盖，规则部分由 `VMacPreference` 测试覆盖。
4. 代理线路页应用了新线路，导致出口规则变化：同一页下方的「加密 DNS 和出口规则」表单不能还拿着旧值去保存。由 Task 4 Step 5 的重新装载和人工核对覆盖。
5. 客机没装好、正在安装或需要恢复存储时：侧栏各项仍可点，页面给出说明，不出现空白页或报错。由 Task 3 的人工核对覆盖。

## 准备

在 `ui` 目录确认基线：`npm run lint` 无输出，`npm test` 为 231 项通过；`bash scripts/test-vmac-shell.sh` 通过。

---

### Task 1: 页面清单

**Files:**
- Create: `ui/src/vmac-pages.mjs`
- Test: `ui/src/vmac-pages.test.mjs`

**Interfaces:**
- Produces:
  - `pageGroups`：`[{ label, pages: [id…] }]`，顺序即侧栏顺序。
  - `pages`：`{ [id]: { title, symbol, subtitle } }`，`symbol` 是 SF Symbols 名称。
  - `pageFor(destination: string): string`，把任何旧名字或新名字变成页面 id，不认识的返回 `"overview"`。
  - `embeddedSections(page: string): string[]`，这个页面里要嵌入的旧「设置」分组。

清单：

| 分组 | id | 标题 | symbol | 嵌入的旧分组 |
|---|---|---|---|---|
| （无） | `overview` | 概览 | `rectangle.grid.2x2` | — |
| 这台客机 | `machines` | 虚拟机与磁盘 | `internaldrive` | — |
| 这台客机 | `system` | 账户与系统 | `person.crop.circle` | `region` |
| 这台客机 | `sharing` | 共享与传输 | `arrow.left.arrow.right` | — |
| 网络 | `proxy` | 代理线路 | `network` | `network` |
| 网络 | `checks` | 环境检测 | `checkmark.shield` | — |
| VMac | `general` | 通用 | `gearshape` | `keyboard`、`appearance` |
| VMac | `security` | 账户与安全 | `lock.shield` | `account`、`vault`、`mobile` |
| VMac | `recovery` | 环境与恢复 | `arrow.counterclockwise` | `project`、`archived-sessions` |
| VMac | `about` | 关于 | `info.circle` | `about` |

副标题：`machines`「切换和新建虚拟机，调整磁盘容量，清理空间。」；`system`「客机的登录账户、时区与语言、输入法。」；`sharing`「Mac 和客机之间怎样共享剪贴板和文件。」；`proxy`「选择出口节点、管理订阅，所有客机共用这套代理。」；`checks`「核对隔离报告、网关保护和 Claude 站点连通。」；`general`「启动方式、键盘习惯和显示。」；`security`「VMac 账户、密码保险箱和远程连接。」；`recovery`「环境存储、组件版本、客机权限和资源。」；`overview` 和 `about` 为空。

旧名字的对应：`lifecycle`、`desktop` 为 `overview`；`space`、`profiles`、`management` 为 `machines`；`login`、`timezone`、`input`、`region` 为 `system`；`network` 为 `proxy`；`settings`、`keyboard`、`appearance` 为 `general`；`account`、`vault`、`mobile` 为 `security`；`project`、`archived-sessions` 为 `recovery`。

- [ ] **Step 1: 写测试**

```js
import test from "node:test";
import assert from "node:assert/strict";
import { pageGroups, pages, pageFor, embeddedSections } from "./vmac-pages.mjs";

const ids = pageGroups.flatMap(group => group.pages);
test("ten pages, each listed once and fully described", () => {
  assert.equal(ids.length, 10);
  assert.equal(new Set(ids).size, 10);
  assert.deepEqual([...ids].sort(), Object.keys(pages).sort());
  for (const id of ids) assert.ok(pages[id].title && pages[id].symbol, id);
});
test("the groups read as in the spec", () => {
  assert.deepEqual(pageGroups.map(group => group.label), ["", "这台客机", "网络", "VMac"]);
  assert.deepEqual(pageGroups[0].pages, ["overview"]);
  assert.deepEqual(pageGroups[3].pages, ["general", "security", "recovery", "about"]);
});
test("every old entry point reaches a page", () => {
  const expected = { lifecycle: "overview", desktop: "overview", space: "machines", profiles: "machines", management: "machines",
    login: "system", timezone: "system", input: "system", region: "system", network: "proxy", settings: "general",
    keyboard: "general", appearance: "general", account: "security", vault: "security", mobile: "security",
    project: "recovery", "archived-sessions": "recovery", about: "about", proxy: "proxy", checks: "checks" };
  for (const [from, to] of Object.entries(expected)) assert.equal(pageFor(from), to, from);
  assert.equal(pageFor("nonsense"), "overview");
  for (const id of ids) assert.equal(pageFor(id), id);
});
test("each old settings section is embedded in exactly one page", () => {
  const sections = ids.flatMap(id => embeddedSections(id));
  assert.deepEqual([...sections].sort(), ["about", "account", "appearance", "archived-sessions", "keyboard", "mobile", "network", "project", "region", "vault"]);
  assert.deepEqual(embeddedSections("overview"), []);
});
```

- [ ] **Step 2: 运行，确认失败**。`cd ui && node --test src/vmac-pages.test.mjs`
- [ ] **Step 3: 实现 `vmac-pages.mjs`**。
- [ ] **Step 4: 运行，确认通过**。
- [ ] **Step 5: 提交**。`git commit -m "Add the VMac page registry"`

### Task 2: 原生侧栏按三组重排

**Files:**
- Modify: `desktop/GuestSidebar.swift`（`CageGuestSidebar` 的 `destinations`、`management`、布局、`select`；删除「窄侧栏」分支和「设置」行）
- Modify: `desktop/Cage.swift`（`selectGuestDestination`、`settings()`、`embeddedControlsRequested` 里对 `lifecycle` 的选择）
- Test: `ui/src/vmac-pages-sync.test.mjs`

**Interfaces:**
- Consumes: Task 1 的清单。
- Produces: 侧栏的页面表写在 `// sidebar-pages:begin` 和 `// sidebar-pages:end` 两行注释之间，每页一行，格式固定为 `("overview", "概览", "rectangle.grid.2x2", ""),`，第四项是所属分组的标题（没有分组为空字符串）。`CageGuestSidebar.select(_:)` 接受新 id；`lifecycle`、`desktop` 选中 `overview`。点击某一项时 `onSelect` 传出新 id；客机卡片仍传出 `desktop`，电源按钮仍传出 `start` 或 `restart`。

- [ ] **Step 1: 写测试**

```js
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pageGroups, pages } from "./vmac-pages.mjs";

test("the native sidebar lists the same pages in the same order", () => {
  const swift = readFileSync(new URL("../../desktop/GuestSidebar.swift", import.meta.url), "utf8");
  const block = swift.slice(swift.indexOf("// sidebar-pages:begin"), swift.indexOf("// sidebar-pages:end"));
  const rows = [...block.matchAll(/\("([\w-]+)", "([^"]+)", "([\w.]+)", "([^"]*)"\)/g)].map(match => match.slice(1));
  const expected = pageGroups.flatMap(group => group.pages.map(id => [id, pages[id].title, pages[id].symbol, group.label]));
  assert.deepEqual(rows, expected);
});
```

- [ ] **Step 2: 运行，确认失败**。
- [ ] **Step 3: 改侧栏**。分组标题用 11 pt、`CagePalette.faint`，左边距和导航项的图标对齐，上方留 14 pt；导航项高 32 pt，不再缩进，不再有展开箭头。删除底部的「设置」行；底部的网速和用量区域保留。删除所有 `compact` 分支（侧栏最窄 180 pt，走不到）和第一期为深色准备的 `resolvingColors` 重新取色逻辑（VMac 只有浅色）。
- [ ] **Step 4: 改 `Cage.swift`**。`selectGuestDestination` 不再特殊处理 `settings`；`settings()` 改为先 `showGuestControls()`，再派发 `cage-guest-navigate`，值为 `general`；`embeddedControlsRequested` 里的 `select("lifecycle")` 改为 `select("overview")`。
- [ ] **Step 5: 运行测试和 Swift 类型检查**（带和不带 `-DCAGE_EMBEDDED_VM`），用离屏渲染看一眼侧栏。
- [ ] **Step 6: 提交**。`git commit -m "Regroup the native sidebar into ten pages"`

### Task 3: 网页外壳按清单显示页面

**Files:**
- Modify: `ui/src/native-guest-home.jsx`
- Create: `ui/src/vmac-shell.mjs` 里新增函数，Test: `ui/src/vmac-shell.test.mjs`

**Interfaces:**
- Consumes: Task 1 的 `pages`、`pageFor`、`embeddedSections`。
- Produces: `opensDesktop(destination, { ready, setup })`，只有 `destination === "desktop"`、客机就绪且不在安装中时为真（点客机卡片的「回到桌面」）。
- 页面内容的组成：

| 页面 | 内容（自上而下） |
|---|---|
| `overview` | `GuestOverview`（安装中时是安装向导） |
| `machines` | `VMProfiles`；已安装时 `DiskCapacity`、`SpaceManagement`，未安装时现有的「还没有安装 macOS」卡片 |
| `system` | `GuestLoginDetails`、`GuestTimezone`、`GuestInputSources`，然后是 Task 4 嵌入的 `region` |
| `sharing` | Task 6 的 `SharingPage` |
| `proxy` | `ProxySettings`，然后是 Task 4 嵌入的 `network` |
| `checks` | `ChecksPage` |
| `general` | Task 7 的 `GeneralPage`，然后是嵌入的 `keyboard`、`appearance` |
| `security`、`recovery`、`about` | Task 4 嵌入的分组 |

`sharing` 和 `general` 的专属内容在 Task 6、Task 7 加入；在那之前，`sharing` 页只有标题和副标题。

- [ ] **Step 1: 写 `opensDesktop` 的测试**：`("desktop", { ready: true, setup: false })` 为真；`ready: false`、`setup: true`、其他 destination 都为假。运行，确认失败；实现；确认通过。
- [ ] **Step 2: 改外壳**。`page` 初值为 `overview`；`titles`、`subtitles` 两张表删除，改用 `pages[page]`；`navigate(destination)` 先 `pageFor`，再按 `opensDesktop` 决定是否打开桌面；`lifecycle` 的判断改为 `page === "overview"`；`useVMacProtection` 的启用条件保持为 `proxy` 或 `checks`；发给原生端的 `destination` 用新 id。`GuestTimezone` 的 `onSettings` 改为滚动到同页下方的时区与语言表单（给嵌入的 `region` 分组加 `id="vmac-region"`）。
- [ ] **Step 3: `cage-guest-settings` 事件改为 `navigate("general")`；`openSettings(value)` 改为 `navigate(pageFor(value))`**，所有调用处不用改。
- [ ] **Step 4: `npm run lint && npm test`，提交**。`git commit -m "Lay the VMac pages out from the page registry"`

### Task 4: 旧「设置」嵌入页面

**Files:**
- Modify: `ui/src/settings.jsx`
- Modify: `ui/src/native-guest-home.jsx`
- Modify: `ui/src/settings.css`（或 `native-guest-home.css` 末尾的 `.vmac-theme` 部分）
- Modify: `ui/src/vmac-pages.mjs`，Test: `ui/src/vmac-pages.test.mjs`

**Interfaces:**
- Produces（`vmac-pages.mjs`）:
  - `settingsFooterVisible({ embedded, section, changed, proxyDirty, saving })`：非嵌入时沿用旧规则（`appearance`、`browser`、`account`、`vault`、`mobile`、`archived-sessions`、`project`、`about` 这些分组只有 `changed` 时显示，其余始终显示）；嵌入时只有 `changed`、`proxyDirty` 或 `saving` 为真才显示。
  - `leavingNeedsConfirm({ changed, accountDirty, proxyDirty, resourceDirty })`：任意一个为真即为真。
- `SettingsPanel` 新增两个属性：`embedded = false`、`sections = []`。嵌入时：不渲染左侧分组栏和「返回工作台」；不注册 Esc 关闭；`sections` 里的每个分组按顺序全部显示；保存成功后不调用 `onClose`；`network` 分组里不再渲染 `ProxySettings`（页面上方已有一份）；最外层加类名 `settings-embedded`；每个分组的最外层加 `id="vmac-<分组名>"`；通过新属性 `onDirtyChange(dirty: boolean)` 把 `leavingNeedsConfirm` 的结果告诉外壳。

- [ ] **Step 1: 写两个函数的测试**。`settingsFooterVisible`：非嵌入 `section: "network"` 且没有改动为真，`section: "about"` 且没有改动为假、有改动为真；嵌入且三项都为假时为假，任一为真时为真。`leavingNeedsConfirm`：四项全假为假，逐项为真时为真。运行，确认失败；实现；确认通过。
- [ ] **Step 2: 改 `SettingsPanel`**。加 `const shows = id => embedded ? sections.includes(id) : section === id;`，把用于决定显示哪个分组的 `section === "…"` 全部换成 `shows("…")`；页脚的显示条件换成 `settingsFooterVisible`。
- [ ] **Step 3: 改外壳**。进入应用时读取一次 `/settings`；每个页面按 `embeddedSections(page)` 嵌入 `SettingsPanel`，`key` 用 `页面 id + 设置的读取次数`，`onSaved` 重新读取 `/settings`；删除文件末尾原来的浮层用法和 `section` 状态。
- [ ] **Step 4: 离开页面前的确认**。外壳记下嵌入的 `SettingsPanel` 报来的 `dirty`；`navigate` 时如果为真，先弹「放弃尚未保存的修改？」（正文「当前环境不会改变。离开后会丢弃这次表单修改。」，按钮「放弃修改」），取消则留在原页并让原生侧栏的选中项回到原页。
- [ ] **Step 5: 代理线路页**。`ProxySettings` 的 `onApplied` 除了现有的刷新状态，还要重新读取 `/settings`，让下方嵌入的表单按新的出口规则重新装载。
- [ ] **Step 6: 样式**。`.settings-embedded` 取消旧「设置」的全屏定位和两栏布局，内容和页面其余部分同宽；页脚吸附在页面底部，样式沿用检测页的 `.vm-safety-actions`。
- [ ] **Step 7: `npm run lint && npm test && npm run build`，用模拟数据截图核对 `system`、`proxy`、`general`、`security`、`recovery`、`about` 六页，提交**。`git commit -m "Show the old settings sections inside the VMac pages"`

### Task 5: 分组列表组件和页面宽度

**Files:**
- Modify: `ui/src/vmac-ui.jsx`，`ui/src/native-guest-home.css`

**Interfaces:**
- Produces: `Group({ title, children })`，圆角 12、底色 `--well` 的分组，`title` 是分组上方的小标题（13/600、`--muted`）；`Row({ title, detail, children })`，左边是标题和一行说明，右边是 `children`，行与行之间有分隔线；`Toggle({ checked, onChange, label, disabled })`，34×20 的开关，是带 `role="switch"` 和 `aria-checked` 的按钮，空格和回车可切换。

- [ ] **Step 1: 实现三个组件和样式**（`.vm-group`、`.vm-row`、`.vm-toggle`），开关的滑块移动用 120 毫秒。
- [ ] **Step 2: 页面宽度**。`.vm-page`、`.vm-card`、`.vm-header` 里的文字区域、`.settings-embedded` 统一为最宽 720 并居中；`proxy` 和 `checks` 两页保持 1040（它们的内部布局是按宽版排的，第二期（下）再收）。标题、提示条和内容左对齐在同一条线上。
- [ ] **Step 3: `npm run lint && npm test`，截图核对 1000 和 1280 两种窗口宽度，提交**。`git commit -m "Add the grouped list components and center the page column"`

### Task 6: 共享与传输页

**Files:**
- Create: `ui/src/vmac-sharing.jsx`
- Modify: `desktop/VMacShell.swift`，`desktop/VMacShellTests.swift`
- Modify: `desktop/Cage.swift`（消息处理、「文件」菜单的两个开关）
- Modify: `internal/maclogin/native_clipboard_darwin.h`（`vmacPreference` 的使用处），`internal/maclogin/native_workbench_darwin.h`（`acceptDrop:perform:`）

**Interfaces:**
- Produces（Swift）:

```swift
enum VMacPreference: String, CaseIterable {
    case shareClipboardContent, hostInputMethod, fileDrop
    var defaultsKey: String { get }        // "vmac.shareClipboardContent", "vmac.hostInputMethod", "vmac.fileDrop"
    func value(in defaults: UserDefaults) -> Bool      // unset means on
    func set(_ value: Bool, in defaults: UserDefaults)
    static func all(in defaults: UserDefaults) -> [String: Bool]   // keyed by rawValue
}
```

- 原生消息：`vmacPreferences` 返回 `all(in:)`；`vmacSetPreference` 接收 `{ key, value }`，`key` 不是三者之一时返回错误。设置后更新「文件」菜单里对应项的勾选，调用 `publishWindowVisibility()`，并向网页派发 `vmac-preferences-changed` 事件。从菜单切换时走同一条路径。
- 网页：`SharingPage()`，一个分组三行，每行一个 `Toggle`：「共享剪贴板」（说明「文字、图片和文件在 Mac 和客机之间双向同步」）、「拖放文件」（「把文件拖进客机画面，或从客机拖到 Mac」）、「用 Mac 输入法在客机中打字」（「客机里请切换到英文（ABC）输入」）。
- Objective-C：`vmac.fileDrop` 关闭时，`acceptDrop:perform:` 返回 `NO`，`askGuestForDrag` 直接返回。

- [ ] **Step 1: 写测试**（用 `UserDefaults(suiteName:)` 建一个临时域，测完删除）：未设置时三项都为真；`set(false)` 后该项为假、其余仍为真；`all(in:)` 的键是 `shareClipboardContent`、`hostInputMethod`、`fileDrop`；`VMacPreference(rawValue: "other")` 为 `nil`。
- [ ] **Step 2: 运行，确认失败；实现；确认通过**。
- [ ] **Step 3: 接原生消息和菜单**，`Cage.swift` 里现有的 `vmacPreference(_:)` 读取改用 `VMacPreference`。
- [ ] **Step 4: Objective-C 端加上 `vmac.fileDrop` 的判断**，`go build -tags cage_macos_only ./internal/maclogin/` 通过。
- [ ] **Step 5: 写 `SharingPage`**，进入页面时读取，监听 `vmac-preferences-changed`，读取失败时在分组下方显示一句原因。
- [ ] **Step 6: 全部检查，提交**。`git commit -m "Add the sharing page with its three switches"`

### Task 7: 通用页

**Files:**
- Create: `ui/src/vmac-general.jsx`
- Modify: `ui/src/vmac-shell.mjs`，`ui/src/vmac-shell.test.mjs`，`ui/src/native-guest-home.jsx`，`ui/src/appearance-settings.jsx`

**Interfaces:**
- Produces: `autoStartEnabled(storage)`（`storage.getItem("vmac.autoStartGuest") !== "0"`，读取出错时为真）；`setAutoStart(storage, enabled)`（开启时删除这个键，关闭时写入 `"0"`，出错时静默）。`GeneralPage()`：一个分组「启动」，一行「打开 VMac 时自动启动客机」（说明「关闭后，需要在概览里手动启动」）。
- 嵌入的 `appearance` 分组在 VMac 里不显示「我的主题」（`ThemeLibrary`），只留字号、指针光标、字体平滑、减少动态效果。

- [ ] **Step 1: 写测试**，用一个带 `getItem`、`setItem`、`removeItem` 的假对象：默认开启；`setAutoStart(false)` 后为关闭、存的值是 `"0"`；再 `setAutoStart(true)` 后键被删除；`getItem` 抛错时 `autoStartEnabled` 为真。
- [ ] **Step 2: 运行，确认失败；实现；确认通过**。外壳里原来直接读 `localStorage` 的那段改用 `autoStartEnabled`，并去掉固定传入的 `attempted: false`（`shouldAutoStart` 的这个参数一并删除，测试同步修改）。
- [ ] **Step 3: 写 `GeneralPage`，隐藏 VMac 里的 `ThemeLibrary`**。
- [ ] **Step 4: 全部检查，提交**。`git commit -m "Add the general page with the auto-start switch"`

### Task 8: 状态胶囊的浮层

**Files:**
- Modify: `desktop/VMacShell.swift`，`desktop/VMacShellTests.swift`，`desktop/VMacToolbar.swift`，`desktop/Cage.swift`
- Modify: `ui/src/native-guest-home.jsx`，`ui/src/vmac-shell.mjs`，`ui/src/vmac-shell.test.mjs`

**Interfaces:**
- Produces（JS）: `statusDetail(status, disk, now)` 返回 `{ network, exit, disk }` 三个字符串：`network` 是 `networkState(status, now).label`；`exit` 是「IP · 国家 · 城市」，没有出口信息时为「尚未取得出口信息」；`disk` 是「64 GiB」这样的容量，未知时为「—」。随 `guestNavigationStatus` 一起发给原生端。
- Produces（Swift）: `struct VMacStatusDetail: Equatable { let network: String; let exit: String; let disk: String; init(body: [String: Any]) }`，缺失的字段为「—」。`VMacToolbarController.update(detail:)`；点击胶囊弹出 `NSPopover`：三行（网络保护、出口、磁盘），下面三个按钮「概览」「代理线路」「环境检测」，分别触发 `onNavigate("overview" / "proxy" / "checks")`。原来的 `onShowOverview` 删除。

- [ ] **Step 1: 写两边的测试**。JS：有出口信息、没有出口信息、没有磁盘三种情况。Swift：完整的字典、空字典。
- [ ] **Step 2: 运行，确认失败；实现；确认通过**。
- [ ] **Step 3: 实现浮层并接线**，浮层的显示和消失用系统默认动画，「减弱动态效果」开启时不动画。
- [ ] **Step 4: 全部检查，提交**。`git commit -m "Open a status popover from the toolbar pill"`

### Task 9: 第一期的遗留

**Files:** 见每一项。

- [ ] **Step 1: 概览小卡片的颜色**（`ui/src/native-guest-home.css` 里 `.vm-tile` 和 `.vm-stat` 的 `busy`、`warn`）：处理中用蓝色，需留意用琥珀色，和状态标签一致。
- [ ] **Step 2: 拖出多个文件时不再盖住失败**（`internal/maclogin/native_clipboard_darwin.h` 的 `CageGuestDragOut`）：记录是否有任何一项失败；最后一项完成时，有失败就显示出错提示「有 N 项没能从客机拷出」，全部成功才显示「已从客机拷出 N 项」。把「全部完成时显示什么」写成 `clipboard_baseline.h` 那样的纯函数 `cageDragOutSummary(total, failed)`（返回 0 表示成功提示，1 表示出错提示），放进新的 `internal/maclogin/drag_out_summary.h`，测试放进 `internal/maclogin/testdata/`，由 `scripts/test-clipboard-baseline.sh` 一并运行（脚本改名为 `scripts/test-maclogin-rules.sh`）。先写测试并确认失败。
- [ ] **Step 3: 工具栏开关**（`desktop/Cage.swift` 的 `toggleControlCenter`）：回到桌面时不再改侧栏的选中项；`guestDesktopCommand` 失败时用出错提示显示原因；`shell.toggleAction() == .none` 时让开关不可点（`VMacToolbarController.setToggleEnabled(_:)`）。
- [ ] **Step 4: 工具栏传文件失败时给提示**：`performEmbeddedUtility("upload")` 返回假时显示「请先打开客机桌面」。
- [ ] **Step 5: 清理**：删除仍在写入但不再读取的 `vmac.windowAppearance`（VMac 模式下不再保存）；动画时长统一到三档（`native-guest-home.css` 和 `GuestSidebar.swift` 里不在三档上的值就近取整）。
- [ ] **Step 6: 卡片样式**：`.vm-card` 去掉边框、底色改为 `--well`；剩下的两处 9 像素圆角改为 `var(--radius-control)`。
- [ ] **Step 7: 「更新待完成」的提示**：窗口标题隐藏后，把这句话加到状态胶囊的说明里（`VMacStatus.detail` 后面加「 · 更新待完成」）。规则写进 `VMacStatus`，先加测试。
- [ ] **Step 8: 窗口关闭或最小化时的快捷键**：`VMacMenuKeys.equivalent(for:mode:)` 增加参数 `windowVisible: Bool`，窗口不可见时一律按控制中心处理。先改测试并确认失败；在窗口的显示、关闭、最小化和恢复时调用 `refreshMenuKeys()`。
- [ ] **Step 9: 应用图标补齐 512@2x 以外缺的几档**（`desktop/VMacLogo.swift` 的 icns 清单加上 `ic11`、`ic12`、`ic13`、`ic14`，分别对应 `icon_16x16@2x`、`icon_32x32@2x`、`icon_128x128@2x`、`icon_256x256@2x`）。
- [ ] **Step 10: 浮动提示最多两行**（`desktop/VMacToast.swift`）：文字超过一行时换行，高度随之增加，最多两行，再长的截断并把全文放进 `toolTip`。
- [ ] **Step 11: 全部检查，提交**。`git commit -m "Clear the leftovers from the first phase"`

### Task 10: 打包和核对

- [ ] **Step 1: 全部检查**。`npm run lint && npm test && npm run build`；`bash scripts/test-vmac-shell.sh`；`bash scripts/test-maclogin-rules.sh`；Swift 类型检查两种配置；`go vet ./internal/workbench/ ./internal/maclogin/ ./cmd/cage/`；`go test ./internal/workbench/ -run 'TestRetryGuestSSH|TestMacOSGuest|TestMacOSNativeTransfer'`。
- [ ] **Step 2: 截图核对十个页面**，窗口宽 1000 和 1280 各一张；离屏渲染侧栏。
- [ ] **Step 3: 增量打包**，签名，运行三项资源校验。
- [ ] **Step 4: 安装并在真机核对**（需要用户参与）：十个侧栏项逐个点开；在「账户与系统」改时区但不保存，切到别的页面时应询问；在「共享与传输」关掉共享剪贴板，「文件」菜单里的勾应同时消失，反过来也一样；点状态胶囊出现浮层；「设置…」菜单项进入「通用」；检测页的「出口规则」进入「代理线路」。
- [ ] **Step 5: 提交打包相关的改动**（如果有）。

## 留给第二期（下）的

- 各页面内部改用分组列表：虚拟机与磁盘、账户与系统、账户与安全、环境与恢复、关于。
- 代理线路和环境检测两页收窄到 720。
- 「通用」里的键盘习惯移到「账户与系统」；CPU 和内存从「环境与恢复」移到「虚拟机与磁盘」。
- 解锁页和安装向导换成新样式。
- 记住上次停留的页面。
