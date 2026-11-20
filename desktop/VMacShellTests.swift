import AppKit

@main
enum VMacShellTests {
    static func main() {
        var shell = VMacShellState()
        precondition(shell.mode == .controlCenter && shell.sidebarVisible)
        precondition(shell.toggleAction() == .none, "no desktop to go to before the guest is ready")
        shell.guestStatusChanged(ready: true)
        precondition(shell.mode == .controlCenter && shell.toggleAction() == .showDesktop)
        shell.desktopPresented()
        precondition(shell.mode == .desktop && !shell.sidebarVisible)
        precondition(shell.toggleAction() == .showControlCenter)
        shell.guestStatusChanged(ready: false)
        precondition(shell.mode == .controlCenter && shell.sidebarVisible, "a lost guest returns to the control center")
        shell.guestStatusChanged(ready: true)
        shell.desktopPresented()
        shell.controlsRequested()
        precondition(shell.mode == .controlCenter && shell.guestReady)

        precondition(VMacStatus(name: "macOS 客机", tone: "ok", detail: "已保护").tone == .ok)
        precondition(VMacStatus(name: "macOS 客机", tone: "???", detail: "").tone == .idle)
        precondition(VMacStatus(name: "a", tone: "busy", detail: "b") == VMacStatus(name: "a", tone: "busy", detail: "b"))

        let connecting = VMacGuestActions(running: true, ready: false)
        precondition(!connecting.upload && connecting.lifecycle, "a guest that is still connecting can be restarted or stopped")
        let ready = VMacGuestActions(running: true, ready: true)
        precondition(ready.upload && ready.lifecycle)
        let stopped = VMacGuestActions(running: false, ready: false)
        precondition(!stopped.upload && !stopped.lifecycle)

        var toast = VMacToastModel()
        precondition(!toast.visible)
        precondition(toast.show("已上传", kind: .info) == 3 && toast.visible && toast.text == "已上传")
        precondition(toast.show("", kind: .info) == nil && !toast.visible, "an empty notice clears an ordinary toast")
        precondition(toast.show("出错了", kind: .error) == nil && toast.visible && toast.kind == .error)
        _ = toast.show("", kind: .info)
        precondition(toast.visible && toast.text == "出错了", "an empty notice must not clear an error")
        precondition(toast.show("已完成", kind: .info) == 3 && toast.text == "已完成", "a new notice replaces an error")
        toast.dismiss()
        precondition(!toast.visible)

        precondition(vmacAppearanceName(for: "light") == .aqua)
        precondition(vmacAppearanceName(for: "dark") == .darkAqua)
        precondition(vmacAppearanceName(for: nil) == nil && vmacAppearanceName(for: "system") == nil)

        for mode in [VMacShellMode.desktop, .controlCenter] {
            let center = VMacMenuKeys.equivalent(for: .controlCenter, mode: mode)
            precondition(center.key == "," && center.modifiers == [.control, .command])
            let full = VMacMenuKeys.equivalent(for: .fullScreen, mode: mode)
            precondition(full.key == "f" && full.modifiers == [.control, .command])
        }
        for (key, expected) in [(VMacMenuKey.quit, "q"), (.hide, "h"), (.minimize, "m"), (.settings, ",")] {
            precondition(VMacMenuKeys.equivalent(for: key, mode: .desktop).key == "", "the guest keeps this shortcut on the desktop")
            let inControls = VMacMenuKeys.equivalent(for: key, mode: .controlCenter)
            precondition(inControls.key == expected && inControls.modifiers == [.command])
        }
        print("VMac shell state, status, toast, appearance and menu key checks passed")
    }
}
