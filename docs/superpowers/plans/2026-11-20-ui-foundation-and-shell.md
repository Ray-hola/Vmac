# 界面第一期：视觉基础和外壳 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 VMac 换成蓝白黑的新外观，并把窗口改成「桌面」和「控制中心」两种状态，客机画面成为主角。

**Architecture:** 颜色只定义一次（`ui/src/vmac-tokens.mjs`），网页样式和原生调色板各有一份副本，由测试保证三处一致。外壳的状态切换、状态胶囊文字、浮动提示的规则都写成不依赖界面的纯逻辑并配测试；原生窗口（`desktop/Cage.swift`）和网页外壳（`ui/src/native-guest-home.jsx`）只负责把这些逻辑接到界面上。

**Tech Stack:** Swift / AppKit（原生窗口、侧栏、工具栏），Objective-C（客机画面所在的视图），React 和纯 CSS（管理页面），Node 自带测试（`node --test`）。

**Spec:** `docs/superpowers/specs/2026-11-20-vmac-native-ui-redesign-design.md`（第 4、6、7 节），`docs/superpowers/specs/2026-11-20-vmac-native-experience-roadmap.md`（第一层）。

## Global Constraints

- 颜色只用设计说明 6.1 的色值，不新增颜色。
- 正文文字和它所在底色的对比度不低于 4.5:1。
- 动效时长只有 120、200、320 毫秒三档，曲线统一为 `cubic-bezier(.2,.8,.2,1)`。系统开启「减弱动态效果」时，位移和缩放改为淡入淡出。
- 桌面状态下 VMac 只占用 `⌃⌘F`（全屏）和 `⌃⌘,`（控制中心），其余快捷键交给客机。
- `capturesSystemKeys` 保持 `NO`；`automaticallyReconfiguresDisplay` 这一期不改。
- 不引入新的界面框架或组件库。不改隔离、代理、检测的行为。
- 最低系统版本 macOS 14.0。本机打包用 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`。
- 界面文字用中文，句式和现有界面一致。代码注释和提交说明用英文。
- 页面重组（十项导航、合并旧「设置」、分组列表组件）属于第二期，这一期不做。

## Review Focus

1. 客机在桌面状态下停止或崩溃：窗口应回到控制中心并显示侧栏，不能停在空白画面。由 Task 4 的 `guestStatusChanged(ready: false)` 测试覆盖。
2. 打开应用时客机还没装好、需要恢复存储或上次操作出错：不能自动启动。由 Task 9 的 `shouldAutoStart` 测试覆盖。
3. 连续多条提示（一次传多个文件）之后出现错误：错误提示不能被后面的空提示清掉。由 Task 4 的 `VMacToastModel` 测试覆盖。
4. 运行中切换系统的浅色和深色：原生部分和网页部分要同时变化，不留旧颜色。由 Task 2、Task 3 的一致性测试和 Task 10 的人工核对覆盖。
5. 桌面状态下按 `⌘Q`、`⌘W`、`⌘H`、`⌘M`、`⌘,`：应作用在客机里的应用上，VMac 不退出、不隐藏。由 Task 6 的 `VMacMenuKeys` 测试和 Task 10 的真机核对覆盖。

## 准备

新工作区里没有被忽略的构建输入。开始前从上一个工作目录 `VMac-native` 复制：`ui/node_modules`、`internal/workbench/web`、`internal/limaembed/assets`。然后在 `ui` 目录确认基线：`npm run lint` 无输出，`npm test` 为 187 项通过。

---

### Task 1: 颜色令牌

**Files:**
- Create: `ui/src/vmac-tokens.mjs`
- Test: `ui/src/vmac-tokens.test.mjs`
- Modify: `docs/superpowers/specs/2026-11-20-vmac-native-ui-redesign-design.md`（6.1 的表）

**Interfaces:**
- Produces: `tokens`（`{ light, dark }`，两边的键相同）；`contrast(hexA, hexB): number`（WCAG 对比度）。键名：`page chrome group popover line ink muted faint accent accentFill accentFillHover accentFillActive accentText accentSoft hover okDot okText warnDot warnText badDot badText onAccent`。

色值（浅色 / 深色）：

| 键 | 浅色 | 深色 |
|---|---|---|
| page | `#FFFFFF` | `#151517` |
| chrome | `#F9FAFB` | `#1B1B1C` |
| group | `#F1F3F5` | `#232324` |
| popover | `#FFFFFF` | `#2C2C2E` |
| line | `rgba(0,0,0,.08)` | `rgba(255,255,255,.1)` |
| ink | `#0F1115` | `#F5F6F7` |
| muted | `#61666B` | `#A8ADB4` |
| faint | `#81858C` | `#7A8089` |
| accent（图标、指示、焦点环） | `#3964FE` | `#5686FE` |
| accentFill / Hover / Active（实心按钮） | `#3964FE` / `#2F56E8` / `#2648CC` | 同浅色 |
| accentText（蓝色文字） | `#2648CC` | `#8FB0FF` |
| accentSoft | `#E4EDFD` | `#252E45` |
| hover | `rgba(38,49,72,.06)` | `rgba(255,255,255,.06)` |
| okDot / okText | `#22C55E` / `#15803D` | `#22C55E` / `#4ED17E` |
| warnDot / warnText | `#F59E0B` / `#B45309` | `#F59E0B` / `#F7AD31` |
| badDot / badText | `#F25A5A` / `#B91C1C` | `#F25A5A` / `#F87171` |
| onAccent | `#FFFFFF` | `#FFFFFF` |

和设计说明第一版相比有三处修正，原因都是对比度：蓝色文字单独用更深（深色下更浅）的 `accentText`；实心按钮在深色下仍用 `#3964FE`，因为白字在 `#5686FE` 上只有约 3.4:1；浅色的 `badText` 由 `#DC2626` 改为 `#B91C1C`。

- [ ] **Step 1: 写测试**

```js
import test from "node:test";
import assert from "node:assert/strict";
import { tokens, contrast } from "./vmac-tokens.mjs";

test("light and dark define the same keys", () => {
  assert.deepEqual(Object.keys(tokens.light).sort(), Object.keys(tokens.dark).sort());
});
test("brand values match the spec", () => {
  assert.equal(tokens.light.accent, "#3964FE");
  assert.equal(tokens.light.ink, "#0F1115");
  assert.equal(tokens.light.page, "#FFFFFF");
  assert.equal(tokens.dark.page, "#151517");
  assert.equal(tokens.dark.accent, "#5686FE");
});
test("contrast follows WCAG", () => {
  assert.equal(Math.round(contrast("#000000", "#FFFFFF")), 21);
  assert.equal(contrast("#3964FE", "#3964FE"), 1);
});
for (const mode of ["light", "dark"]) {
  const t = tokens[mode];
  const pairs = [["ink", "page"], ["ink", "group"], ["muted", "page"], ["muted", "group"],
    ["accentText", "page"], ["accentText", "group"], ["accentText", "accentSoft"],
    ["okText", "group"], ["warnText", "group"], ["badText", "group"], ["onAccent", "accentFill"],
    ["onAccent", "accentFillHover"], ["onAccent", "accentFillActive"]];
  for (const [text, surface] of pairs) {
    test(`${mode}: ${text} on ${surface} is at least 4.5:1`, () => {
      assert.ok(contrast(t[text], t[surface]) >= 4.5, `${t[text]} on ${t[surface]}`);
    });
  }
}
```

- [ ] **Step 2: 运行，确认失败**。`cd ui && node --test src/vmac-tokens.test.mjs`，预期因找不到模块而失败。
- [ ] **Step 3: 实现 `vmac-tokens.mjs`**。`contrast` 只接受 `#RRGGBB`。如果某一对达不到 4.5，把文字色在浅色下调深、深色下调浅，直到通过，并同步改上面的表。
- [ ] **Step 4: 运行，确认通过**。
- [ ] **Step 5: 更新设计说明 6.1 的表**，和上表一致。
- [ ] **Step 6: 提交**。`git commit -m "Add the VMac color tokens with contrast checks"`

### Task 2: 网页主题

**Files:**
- Create: `ui/src/vmac-theme.css`
- Test: `ui/src/vmac-theme.test.mjs`
- Modify: `ui/src/native-guest-home.css`（删除第 7 到 19 行的旧 `:root.vmac-theme` 块，替换文件里写死的旧色值）
- Modify: `ui/src/native-guest-home.jsx`（在引入 `native-guest-home.css` 之前引入 `vmac-theme.css`）

**Interfaces:**
- Consumes: Task 1 的 `tokens`。
- Produces: `.vmac-theme` 下的 CSS 变量。沿用现有变量名并映射：`--paper`=page，`--chrome`=chrome，`--chrome-dark`=group，`--well`=group，`--card`=popover，`--input`=popover，`--line` 和 `--border`=line，`--ink` 和 `--strong`=ink，`--muted`=muted，`--accent`、`--focus`=accent，`--button`=accentFill，`--button-ink`=onAccent，`--link`=accentText，`--hover`=hover，`--selected` 和 `--accent-soft`=accentSoft，`--selection`=accentSoft，`--success`=okText，`--warn`=warnText，`--danger`=badText。新增：`--faint`、`--accent-text`、`--button-hover`、`--button-active`、`--ok-dot`、`--warn-dot`、`--bad-dot`、`--success-soft`、`--warn-soft`、`--danger-soft`（各自圆点色的 12%）、`--radius-group: 12px`、`--radius-control: 8px`、`--radius-tag: 6px`、`--vm-ease: cubic-bezier(.2,.8,.2,1)`、`--vm-fast: 120ms`、`--vm-mid: 200ms`、`--vm-slow: 320ms`。
- 深色的选择器：`:root.vmac-theme[data-vmac-appearance="dark"]`，以及 `@media (prefers-color-scheme: dark)` 下的 `:root.vmac-theme:not([data-vmac-appearance="light"])`。`color-scheme` 随之为 `light` 或 `dark`。

- [ ] **Step 1: 写测试**

```js
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { tokens } from "./vmac-tokens.mjs";

const css = readFileSync(new URL("./vmac-theme.css", import.meta.url), "utf8");
const block = selector => css.slice(css.indexOf(selector)).split("}")[0].toLowerCase();
const has = (text, name, value) => text.includes(`${name}: ${value.toLowerCase()}`);

test("light variables come from the tokens", () => {
  const light = block(":root.vmac-theme {");
  for (const [name, key] of [["--paper", "page"], ["--chrome", "chrome"], ["--ink", "ink"], ["--muted", "muted"],
    ["--accent", "accent"], ["--button", "accentFill"], ["--link", "accentText"], ["--danger", "badText"]]) {
    assert.ok(has(light, name, tokens.light[key]), `${name} should be ${tokens.light[key]}`);
  }
});
test("dark variables come from the tokens", () => {
  const dark = block(':root.vmac-theme[data-vmac-appearance="dark"]');
  for (const [name, key] of [["--paper", "page"], ["--ink", "ink"], ["--accent", "accent"], ["--link", "accentText"]]) {
    assert.ok(has(dark, name, tokens.dark[key]), `${name} should be ${tokens.dark[key]}`);
  }
});
test("no stylesheet keeps the retired palette", () => {
  const retired = /#a64d2f|#933f24|#faf9f5|#fffefb|#f0eee7|#e8e5db|#dcd7cb|#716d64|#527052|#a43830|#b2741d|166, 77, 47|38, 38, 36/i;
  const dir = new URL(".", import.meta.url);
  for (const file of readdirSync(dir).filter(name => name.endsWith(".css"))) {
    const text = readFileSync(new URL(file, dir), "utf8");
    assert.ok(!retired.test(text), `${file} still uses a retired color`);
  }
});
```

- [ ] **Step 2: 运行，确认失败**。`node --test src/vmac-theme.test.mjs`
- [ ] **Step 3: 写 `vmac-theme.css`，删除旧块，把各 CSS 文件里命中的旧色值改成对应变量**（阴影里的 `rgba(38, 38, 36, …)` 改为 `rgba(15, 17, 21, …)`）。
- [ ] **Step 4: 运行全部界面检查**。`npm run lint && npm test`，预期全部通过。
- [ ] **Step 5: 提交**。`git commit -m "Move the VMac theme to the blue palette with a dark variant"`

### Task 3: 原生调色板和标志

**Files:**
- Create: `desktop/VMacPalette.swift`
- Test: `ui/src/vmac-palette-sync.test.mjs`
- Modify: `desktop/GuestSidebar.swift:3-16`（删除 `CagePalette`，改用新文件里的同名枚举）
- Modify: `desktop/VMacLogo.swift:23,36`（标志改为 `#3964FE`，图标底色改为 `#FFFFFF`）
- Modify: `ui/src/logo.png`（用 `VMacLogo.swift` 重新渲染）
- Modify: `scripts/build-vmac.sh:78`（把新增的 Swift 文件加入编译列表）

**Interfaces:**
- Consumes: Task 1 的 `tokens`。
- Produces: `enum CagePalette`，成员都是随外观变化的 `NSColor`：`paper card sidebar group ink muted faint accent accentText accentSoft line hover success warn danger`，以及原有的 `mono(_:weight:)`。每个用十六进制定义的成员写成一行，格式固定：`static let accent = dynamic(0x3964FE, 0x5686FE) // token: accent`。`line`、`hover` 用带透明度的黑或白。

- [ ] **Step 1: 写测试**

```js
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { tokens } from "./vmac-tokens.mjs";

test("the native palette matches the tokens", () => {
  const swift = readFileSync(new URL("../../desktop/VMacPalette.swift", import.meta.url), "utf8");
  const rows = [...swift.matchAll(/dynamic\(0x([0-9A-F]{6}), 0x([0-9A-F]{6})\) \/\/ token: (\w+)/g)];
  assert.ok(rows.length >= 11, "expected every hex member to carry a token name");
  for (const [, light, dark, key] of rows) {
    assert.equal(`#${light}`, tokens.light[key], `light ${key}`);
    assert.equal(`#${dark}`, tokens.dark[key], `dark ${key}`);
  }
});
```

- [ ] **Step 2: 运行，确认失败**。
- [ ] **Step 3: 实现 `VMacPalette.swift`**，成员和令牌的对应：paper=page，card=popover，sidebar=chrome，group=group，ink，muted，faint，accent，accentText，accentSoft，success=okDot，warn=warnDot，danger=badDot。
- [ ] **Step 4: 运行测试，并做 Swift 类型检查**。`xcrun swiftc -typecheck -sdk "$SDKROOT" -target arm64-apple-macosx14.0 -parse-as-library desktop/Cage.swift desktop/GuestSidebar.swift desktop/VMacPalette.swift desktop/MacKeyboard.swift desktop/NativeInput.swift desktop/Updates.swift desktop/AccountDevice.swift desktop/MacGuestLogin.swift`，预期没有错误。
- [ ] **Step 5: 改标志颜色，重新渲染 `ui/src/logo.png`**（512 像素，透明底，只有标志）。
- [ ] **Step 6: 提交**。`git commit -m "Give the native palette light and dark blue-white-black colors"`

### Task 4: 外壳逻辑

**Files:**
- Create: `desktop/VMacShell.swift`
- Test: `desktop/VMacShellTests.swift`
- Create: `scripts/test-vmac-shell.sh`（照 `scripts/test-app-updates.sh` 的写法，编译这两个文件并运行）

**Interfaces:**
- Produces:

```swift
enum VMacShellMode: Equatable { case desktop, controlCenter }
enum VMacShellAction: Equatable { case showDesktop, showControlCenter, none }
struct VMacShellState: Equatable {
    private(set) var mode: VMacShellMode       // starts as .controlCenter
    private(set) var guestReady: Bool          // starts as false
    mutating func guestStatusChanged(ready: Bool)   // leaving ready while on the desktop returns to .controlCenter
    mutating func desktopPresented()
    mutating func controlsRequested()
    func toggleAction() -> VMacShellAction
    var sidebarVisible: Bool { get }           // true only in .controlCenter
}
enum VMacTone: String { case busy, ok, warn, bad, idle }   // unknown strings map to .idle
struct VMacStatus: Equatable { let tone: VMacTone; let title: String; let detail: String
    init(name: String, tone: String, detail: String) }
enum VMacToastKind { case info, error }
struct VMacToastModel {
    private(set) var text: String
    private(set) var kind: VMacToastKind
    var visible: Bool { get }
    /// Seconds until the toast hides itself; nil when it stays until dismissed.
    mutating func show(_ text: String, kind: VMacToastKind) -> TimeInterval?
    mutating func dismiss()
}
func vmacAppearanceName(for setting: String?) -> NSAppearance.Name?   // "light" -> .aqua, "dark" -> .darkAqua, anything else -> nil
enum VMacMenuKey { case quit, hide, minimize, settings, controlCenter, fullScreen }
enum VMacMenuKeys { static func equivalent(for key: VMacMenuKey, mode: VMacShellMode) -> (key: String, modifiers: NSEvent.ModifierFlags) }
```

- [ ] **Step 1: 写测试**（`@main enum VMacShellTests`，用 `precondition`，和 `NativeInputTests.swift` 的写法一致）。断言：
  - 初始：`mode == .controlCenter`，`sidebarVisible`，`toggleAction() == .none`。
  - `guestStatusChanged(ready: true)` 后 `toggleAction() == .showDesktop`。
  - `desktopPresented()` 后 `mode == .desktop`，`!sidebarVisible`，`toggleAction() == .showControlCenter`。
  - 在桌面状态下 `guestStatusChanged(ready: false)`：`mode == .controlCenter`，`sidebarVisible`。
  - `controlsRequested()` 后 `mode == .controlCenter`，`guestReady` 不变。
  - `VMacStatus(name: "macOS 客机", tone: "ok", detail: "已保护").tone == .ok`；`tone: "???"` 得到 `.idle`。
  - 提示：`show("已上传", kind: .info) == 3`；`show("出错了", kind: .error) == nil`；出错提示显示时 `show("", kind: .info)` 不改变内容且仍 `visible`；普通提示显示时 `show("", kind: .info)` 后 `!visible`；`dismiss()` 后 `!visible`。
  - 外观：`"light"` 为 `.aqua`，`"dark"` 为 `.darkAqua`，`nil` 和 `"system"` 为 `nil`。
  - 快捷键：`.controlCenter` 在两种状态下都是 `(",", [.control, .command])`；`.fullScreen` 都是 `("f", [.control, .command])`；`.quit`、`.hide`、`.minimize`、`.settings` 在 `.desktop` 下 `key == ""`，在 `.controlCenter` 下分别是 `"q"`、`"h"`、`"m"`、`","` 配 `[.command]`。
- [ ] **Step 2: 运行，确认失败**。`bash scripts/test-vmac-shell.sh`
- [ ] **Step 3: 实现 `VMacShell.swift`**。
- [ ] **Step 4: 运行，确认通过**，输出一行 `VMac shell state, status, toast, appearance and menu key checks passed`。
- [ ] **Step 5: 提交**。`git commit -m "Add the shell state, status, toast and menu key rules"`

### Task 5: 工具栏

**Files:**
- Create: `desktop/VMacToolbar.swift`
- Modify: `desktop/Cage.swift`（窗口创建处 105 到 112 行；`guestNavigationStatus` 处理处 747 行附近）
- Modify: `ui/src/native-guest-home.jsx`（`publishNavigation`，115 到 126 行）
- Create: `ui/src/vmac-shell.mjs`，Test: `ui/src/vmac-shell.test.mjs`

**Interfaces:**
- Consumes: Task 4 的 `VMacStatus`、`VMacTone`；Task 3 的 `CagePalette`。
- Produces（Swift）:

```swift
final class VMacToolbarController: NSObject, NSToolbarDelegate {
    var onToggleControlCenter: (() -> Void)?
    var onShowOverview: (() -> Void)?     // clicking the status pill
    var onUpload: (() -> Void)?
    var onFullScreen: (() -> Void)?
    var onRestart: (() -> Void)?
    var onStop: (() -> Void)?
    func install(in window: NSWindow)     // .unifiedCompact toolbar, hidden title
    func update(_ status: VMacStatus)
    func setControlCenterActive(_ active: Bool)
    func setGuestActionsEnabled(_ enabled: Bool)
}
```

- Produces（JS）: `shellStatus(status, { setup = false, now = Date.now() } = {})`，返回 `{ tone, detail }`。按顺序取第一条满足的：没有 `status` 为 `idle`「正在读取」；`job.running` 为 `busy`，文字按 `job.kind` 取「正在启动」「正在重启」「正在停止」，其他为「处理中」；`job.error` 为 `bad`「操作未完成」；`setup` 为 `warn`「需要完成设置」；`!vm_running` 为 `idle`「已停止」；`!ready` 为 `busy`「连接中」；之后按 `networkState(status, now).mode`：`open` 为 `ok`「已保护」，`checking` 为 `busy`「正在检查网络」，`closed` 为 `warn`「外网已关闭」，其余为 `warn`「外网状态待确认」。
- `guestNavigationStatus` 的消息体新增 `tone` 和 `detail` 两个字符串字段。

- [ ] **Step 1: 写 `shellStatus` 的测试**，上面每条规则一个用例，另加一条顺序用例：`{ vm_running: true, ready: true, job: { running: true, kind: "restart" } }` 得到 `{ tone: "busy", detail: "正在重启" }`。
- [ ] **Step 2: 运行，确认失败；实现；运行，确认通过**。
- [ ] **Step 3: 实现 `VMacToolbarController`**。从左到右：控制中心开关（符号 `sidebar.left`）、弹性空白、状态胶囊（圆点 7 pt 加「客机名 · 状态」，12 pt 字，底色 `CagePalette.group`，全圆角）、弹性空白、传文件（`square.and.arrow.up`）、全屏（`arrow.up.left.and.arrow.down.right`）、更多（`ellipsis`，菜单里是「重启客机」「停止客机」）。圆点颜色：busy 用 accent，ok 用 success，warn 用 warn，bad 用 danger，idle 用 faint。busy 时圆点缓慢呼吸，「减弱动态效果」开启时不动。每个按钮有 `toolTip` 和无障碍标签。
- [ ] **Step 4: 在 `Cage.swift` 里接上**。VMac 模式下安装工具栏；胶囊点击和「重启」「停止」先 `showGuestControls()`，再分别派发网页事件 `cage-guest-navigate`（值为 `lifecycle`）、`vmac-toolbar-restart`、`vmac-toolbar-stop`；传文件调用 `performEmbeddedUtility("upload")`；全屏调用 `window.toggleFullScreen(nil)`。收到 `guestNavigationStatus` 时用 `tone` 和 `detail` 更新胶囊。
- [ ] **Step 5: 网页端在 `native-guest-home.jsx` 监听 `vmac-toolbar-restart` 和 `vmac-toolbar-stop`**，调用现有的重启和停止流程（保留确认弹窗）；`publishNavigation` 带上 `shellStatus` 的结果。
- [ ] **Step 6: 类型检查、`npm run lint && npm test`、提交**。`git commit -m "Add the unified toolbar with the guest status pill"`

### Task 6: 两种状态、侧栏收放和快捷键

**Files:**
- Modify: `desktop/Cage.swift`（侧栏初始化 138 到 163 行；分栏代理 325 到 349 行；`showGuestControls` 422 行；`guestDesktopCommand` 成功回调 616 行；`makeMenus` 234 行起；外观 101 到 109 行和 641 到 651 行）
- Modify: `desktop/GuestSidebar.swift`（`SidebarMachineCard`、`CageGuestSidebar` 的布局和 `showNotice`）

**Interfaces:**
- Consumes: Task 4 的 `VMacShellState`、`VMacMenuKeys`、`vmacAppearanceName`；Task 5 的 `VMacToolbarController`。
- Produces: `CageApp` 的 `private func applyShell(animated: Bool)`，按 `shell.sidebarVisible` 设置侧栏宽度（可见时为记住的宽度，默认 220，范围 180 到 280，新的存储键 `vmac.sidebarWidth.v2`；不可见时为 0 并隐藏分隔线），同时调用 `toolbar.setControlCenterActive` 和菜单快捷键更新。

- [ ] **Step 1: 状态接线**。`guestDesktopCommand` 成功时 `shell.desktopPresented()`；`showGuestControls()` 里 `shell.controlsRequested()`；`guestNavigationStatus` 里 `shell.guestStatusChanged(ready: running && ready && !busy && !failed)`；三处之后都调用 `applyShell(animated: true)`。工具栏开关按 `shell.toggleAction()` 决定调用 `guestDesktopCommand` 还是 `showGuestControls()`。
- [ ] **Step 2: 侧栏动画**。宽度变化用 200 毫秒和统一曲线；「减弱动态效果」开启时直接切换。桌面和控制中心之间的内容切换沿用 `fadeGuestContent()`，时长改为 320 毫秒。
- [ ] **Step 3: 侧栏样式**。顶部的客机卡片改为：状态圆点、客机名、一行蓝色文字「回到桌面」（客机未就绪时为状态文字，不可点）。导航项高度 32，圆角 8，选中项底色 `accentSoft`、文字 `accentText`、字重 500。删除 `showNotice` 的气泡实现（Task 7 接管）。底部的网速、用量、状态灯只换配色。
- [ ] **Step 4: 菜单和快捷键**。VMac 模式下：隐藏「文件」菜单里只属于旧工作台的项（打开项目、新建网页、新建终端、关闭当前标签）；「窗口」菜单新增「控制中心」；「进入全屏」「控制中心」「退出 VMac…」「隐藏 VMac」「最小化」「设置…」的快捷键全部按 `VMacMenuKeys.equivalent(for:mode:)` 设置，并在每次 `applyShell` 时刷新。窗口的 `collectionBehavior` 加上 `.fullScreenPrimary`。
- [ ] **Step 5: 外观**。VMac 模式下不再把窗口固定为浅色。窗口外观取 `vmacAppearanceName(for: UserDefaults.standard.string(forKey: "vmac.appearance"))`，窗口底色用 `CagePalette.paper`。把这个设置值作为 `data-vmac-appearance` 写到网页的根元素上（`system` 时不写）。
- [ ] **Step 6: 类型检查，运行 `bash scripts/test-vmac-shell.sh`，提交**。`git commit -m "Switch the window between the guest desktop and the control center"`

### Task 7: 浮动提示

**Files:**
- Create: `desktop/VMacToast.swift`
- Modify: `desktop/Cage.swift:432-436`（`embeddedControlsRequested` 里对 `notice:` 的处理）
- Modify: `internal/maclogin/native_workbench_darwin.h`（`CageNativeVMWindow` 的 `showNotice:` 和 `runAgent:` 的完成回调）
- Modify: `internal/maclogin/native_clipboard_darwin.h`（`clipboardNotice`）

**Interfaces:**
- Consumes: Task 4 的 `VMacToastModel`、`VMacToastKind`。
- Produces: `final class VMacToastView: NSView`，`func show(_ text: String, kind: VMacToastKind)`。放在内容区最上层、底部居中、距底 20 pt；深色胶囊（底色 `#0F1115` 92%，白字 12 pt，左侧图标：普通为对勾，出错为感叹号），全圆角；淡入并上移 6 pt，200 毫秒；出错提示带关闭按钮，点击后消失。
- Objective-C 端新增 `- (void)showError:(NSString *)message`，通过现有回调发送 `error:<文字>`；`showNotice:` 仍发送 `notice:<文字>`。失败原因改走 `showError:`。

- [ ] **Step 1: 实现 `VMacToastView`**，显示规则全部来自 `VMacToastModel`，定时用它返回的秒数。
- [ ] **Step 2: `embeddedControlsRequested` 里 `notice:` 调 `toast.show(text, kind: .info)`，`error:` 调 `toast.show(text, kind: .error)`**。
- [ ] **Step 3: Objective-C 端改用 `showError:` 报告失败**；`clipboardNotice` 的调用处按是否为失败选择两者之一。
- [ ] **Step 4: 类型检查和 `CGO_ENABLED=1 go vet ./internal/maclogin/`，提交**。`git commit -m "Show transfer results as a toast over the guest"`

### Task 8: 拖入描边

**Files:**
- Modify: `internal/maclogin/native_workbench_darwin.h`（`CageDropVMView` 的 `draggingEntered:`、`draggingExited:`、`performDragOperation:`、`draggingEnded:`）

- [ ] **Step 1: 可以接收的拖动进入时，在视图内侧显示 3 pt 的描边**，颜色 `#3964FE`，圆角 6，120 毫秒淡入；离开、放下或结束时淡出。不能接收时不显示。
- [ ] **Step 2: `go vet ./internal/maclogin/`，提交**。`git commit -m "Outline the guest view while files are dragged over it"`

### Task 9: 启动页和自动启动

**Files:**
- Modify: `ui/src/vmac-shell.mjs`，`ui/src/vmac-shell.test.mjs`
- Modify: `ui/src/vmac-overview.jsx`，`ui/src/native-guest-home.jsx`，`ui/src/native-guest-home.css`

**Interfaces:**
- Produces: `shouldAutoStart(status, { enabled, attempted, installed, setup })`，返回布尔值。只有同时满足才为真：`enabled`、`!attempted`、`installed`、`!setup`、有 `status`、`!status.vm_running`、`!status.job?.running`、`!status.job?.error`、`!status.storage_recovery?.required`。
- 设置存在 `localStorage` 的 `vmac.autoStartGuest`，值为 `"0"` 时关闭，其余为开启。开关界面在第二期。

- [ ] **Step 1: 写测试**。全部满足时为真；逐个破坏上面九个条件，每个一条用例，都为假。
- [ ] **Step 2: 运行，确认失败；实现；运行，确认通过**。
- [ ] **Step 3: 在 `native-guest-home.jsx` 第一次拿到状态后调用一次**，为真时走现有的启动流程，并把 `attempted` 记为真（每次打开应用只尝试一次）。
- [ ] **Step 4: 启动页**。`GuestOverview` 在启动、重启或连接中时显示居中的启动页，取代状态卡片：标志 56 像素、标题（沿用现有的「正在启动客机」等文字）、四步进度（沿用 `stepStates` 的结果）、当前这一步的说明。四步横排，已完成的为蓝色实心圆点，进行中的呼吸，未开始的为灰色。客机就绪后沿用现有逻辑自动进入桌面。
- [ ] **Step 5: `npm run lint && npm test`，提交**。`git commit -m "Start the guest on launch and show a calm boot view"`

### Task 10: 通用样式、打包和核对

**Files:**
- Modify: `ui/src/native-guest-home.css`（共用的 `.vm-*` 类）
- Modify: `scripts/build-vmac.sh`（确认新增的三个 Swift 文件都在编译列表里）

- [ ] **Step 1: 按设计说明 6.2 到 6.4 调整共用样式**：页面标题 22/600；卡片和分组圆角 12、去掉阴影、底色 `--well`；按钮高 32、圆角 8，主要按钮用 `--button`，悬停 `--button-hover`，按下 `--button-active`；状态标签用圆点加文字；焦点环为 3 像素的 `--accent` 35%；页面内容最宽 720 并居中。
- [ ] **Step 2: 全部检查**。`npm run lint && npm test && npm run build`；`bash scripts/test-vmac-shell.sh`；Swift 类型检查（带和不带 `-D CAGE_EMBEDDED_VM` 各一次）；`go vet ./internal/workbench/ ./internal/maclogin/ ./cmd/cage/`。
- [ ] **Step 3: 用模拟数据渲染页面截图**，浅色和深色各一套：启动页、概览（已停止、就绪、出错）、存储空间、客机账户、代理管理、环境检测、设置、解锁页；窗口宽 1000 和 1280 各一张。逐张核对：没有旧配色、文字不溢出、对齐一致。
- [ ] **Step 4: 增量打包为 Build 60**（重新编译 `libVMac.a`、`vmac`、启动器，重新渲染图标），签名，运行 `verify-web-assets`、`verify-vm-assets`、`verify-macos-guest`。
- [ ] **Step 5: 安装并在真机核对**（需要用户参与）：打开应用后自动启动并进入桌面；工具栏开关进出控制中心；传一个文件看到浮动提示；拖入时出现描边；`⌃⌘F` 进出全屏；`⌃⌘,` 呼出控制中心；桌面状态下在客机里按 `⌘Q`、`⌘W`、`⌘,` 作用在客机应用上；把系统切到深色，原生部分和网页部分一起变化；开启「减弱动态效果」后没有位移动画。
- [ ] **Step 6: 提交**。`git commit -m "Restyle the shared VMac components and package the first phase"`

## 留给后面几期的

- 状态胶囊的浮层（网络保护、出口、磁盘和操作）：第二期，这一期点击胶囊进入「概览」。
- 全屏时控制中心以浮层盖在客机画面上、全屏标识线：和「画面跟随窗口」一起做。这一期全屏下呼出控制中心时不退出全屏，但会占满窗口。
- 十项导航、合并旧「设置」、分组列表组件、外观和自动启动的开关界面：第二期。
