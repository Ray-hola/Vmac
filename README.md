# VMac

<img alt="VMac 标志" align="right" width="84" src="assets/branding/vmac-otter.png">

VMac 是 Apple Silicon Mac 上的 macOS 虚拟机工作台。客机画面通过 Apple Virtualization.framework 嵌在同一个应用窗口里，可运行 Claude Desktop 和其他 macOS 应用。

- **虚拟机管理**可新建或切换客机，查看和扩大虚拟磁盘，并在已启动的客机内使用 Mole 扫描缓存。
- **代理管理**提供 Mihomo 节点、订阅和流量；**环境检测**集中显示隔离报告、网关保护，以及 Claude 和站点连通检测。各客机共用 VMac 的代理设置，实际连接状态按当前客机显示。
- 每台客机都有独立的磁盘、安装进度和文件授权。VMac 的原生工作台支持手动上传文件及文字、图片剪贴板同步。

## 下载

从 [GitHub Releases](https://github.com/Ray-hola/Vmac/releases/latest) 获取 Apple Silicon 版应用、校验文件和发行说明。

## 构建

使用 Apple Silicon Mac，准备 Xcode Command Line Tools、Go（版本见 [go.mod](go.mod)）、Node.js 和 Python 3。SSHFS 的构建还需要与 [依赖锁定文件](scripts/guest-os/macos-sshfs-dependencies.json) 一致的 Homebrew GLib、gettext 和 PCRE2。其余构建步骤见 [构建脚本](scripts/build-vmac.sh)。

```sh
bash scripts/build-vmac.sh
open _output/VMac.app
```

脚本生成签名后的 `_output/VMac.app`。再次构建可用 `VMAC_BUILD_OUTPUT` 指定一个尚不存在的绝对 `.app` 路径。

## 数据与升级

主数据在 `~/.vmac`，下载目录在 `~/.vmac-downloads`。启动新版时会导入旧 VMac 应用身份下的客机列表、当前客机和侧栏偏好。启动已安装的客机时，VMac 会在联网检查前同步版本不一致的随附组件。原客机磁盘和账户继续使用。同步失败时可在工作台重试，安装器会恢复可回退的原有组件文件。

应用内更新使用 VMac 自己的 GitHub Releases。ZIP 供手动安装。要启用一键更新，先手动安装由 VMac 发布者使用 Developer ID 签名、公证的应用。后续版本使用同一团队签名，在 Release 中提供 `VMac-<版本>-macos-arm64.dmg` 和 `SHA256SUMS`。磁盘映像内的应用命名为 `VMac.app`，构建时通过 `VMAC_SIGNING_IDENTITY` 传入发布者签名身份。发布前应验证下载的磁盘映像及其中应用均通过 macOS 公证校验。

### Agent 命令行安装

Agent 可以运行 [安装脚本](scripts/install-vmac.sh)。签名 DMG 使用指定发行版本和可信的 Developer ID 团队 ID。手动发行的 ZIP 先核对发布页的 SHA-256，再使用 `local` 模式。替换前应正常关闭客机和 VMac，安装器会保留旧应用备份。

```sh
bash scripts/install-vmac.sh release "$VMAC_RELEASE_VERSION" "$VMAC_PUBLISHER_TEAM_ID" /Applications/VMac.app
bash scripts/install-vmac.sh local "$VMAC_TEST_ZIP" "$VMAC_TEST_SHA256" "$VMAC_TEST_TARGET"
```

ZIP 安装目标使用绝对路径，文件名为 `VMac.app`。正式签名的应用使用 `release` 模式更新。

从仍使用旧数据目录的版本迁移时，先完全退出旧应用，再运行 `_output/VMac.app/Contents/Resources/vmac vmac-migrate`。原客机在「虚拟机管理 → 虚拟机切换 → 原有 macOS 客机」。

## 来源与许可

VMac 基于 [Claude Cage](https://github.com/Lee-xeo/Claude-Cage) 与 [agent-vm](https://github.com/sylvinus/agent-vm) 开发。原作者、贡献者和第三方组件的署名及许可见 [LICENSE](LICENSE)、[NOTICE](NOTICE) 和 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。
