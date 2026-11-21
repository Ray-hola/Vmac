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

        let detail = VMacStatusDetail(body: ["network": "外网已放行", "exit": "203.0.113.7 · 日本", "disk": "64 GiB", "tone": "ok"])
        precondition(detail.network == "外网已放行" && detail.exit == "203.0.113.7 · 日本" && detail.disk == "64 GiB")
        precondition(VMacStatusDetail(body: [:]) == VMacStatusDetail(network: "—", exit: "—", disk: "—"), "missing fields read as a dash")
        precondition(VMacStatusDetail(body: ["network": "", "disk": 64]).network == "—", "an empty or mistyped field reads as a dash")
        precondition(VMacStatusDetail(body: ["network": "", "disk": 64]).disk == "—")

        let suite = "cn.ovenray.vmac.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(VMacPreference.allCases.allSatisfy { $0.value(in: defaults) }, "every sharing switch starts on")
        VMacPreference.fileDrop.set(false, in: defaults)
        precondition(!VMacPreference.fileDrop.value(in: defaults))
        precondition(VMacPreference.shareClipboardContent.value(in: defaults) && VMacPreference.hostInputMethod.value(in: defaults))
        precondition(VMacPreference.all(in: defaults) == ["shareClipboardContent": true, "hostInputMethod": true, "fileDrop": false])
        precondition(VMacPreference.fileDrop.defaultsKey == "vmac.fileDrop" && VMacPreference.shareClipboardContent.defaultsKey == "vmac.shareClipboardContent")
        precondition(VMacPreference(rawValue: "other") == nil)

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

        let fullScreen = vmacFullScreenOptions()
        precondition(fullScreen.contains(.fullScreen) && fullScreen.contains(.autoHideToolbar) && fullScreen.contains(.autoHideMenuBar),
                     "in full screen the toolbar hides until the pointer reaches the top edge")

        for mode in [VMacShellMode.desktop, .controlCenter] {
            for visible in [true, false] {
                let center = VMacMenuKeys.equivalent(for: .controlCenter, mode: mode, windowVisible: visible)
                precondition(center.key == "," && center.modifiers == [.control, .command])
                let full = VMacMenuKeys.equivalent(for: .fullScreen, mode: mode, windowVisible: visible)
                precondition(full.key == "f" && full.modifiers == [.control, .command])
            }
        }
        for (key, expected) in [(VMacMenuKey.quit, "q"), (.hide, "h"), (.minimize, "m"), (.settings, ",")] {
            precondition(VMacMenuKeys.equivalent(for: key, mode: .desktop, windowVisible: true).key == "", "the guest keeps this shortcut on the desktop")
            let inControls = VMacMenuKeys.equivalent(for: key, mode: .controlCenter, windowVisible: true)
            precondition(inControls.key == expected && inControls.modifiers == [.command])
            // A closed or minimized window shows no guest, so nothing is left to keep the shortcut for.
            let hidden = VMacMenuKeys.equivalent(for: key, mode: .desktop, windowVisible: false)
            precondition(hidden.key == expected && hidden.modifiers == [.command], "with no window the Mac shortcut works again")
        }

        precondition(VMacStatus(name: "默认", tone: "ok", detail: "已保护").detail == "已保护")
        precondition(VMacStatus(name: "默认", tone: "ok", detail: "已保护", updatePending: true).detail == "已保护 · 更新待完成")
        precondition(VMacStatus(name: "默认", tone: "idle", detail: "", updatePending: true).detail == "更新待完成")
        // The divider drags the sidebar from a rail of icons to a full list.
        precondition(VMacSidebarWidth.restored(nil) == 220, "a first launch opens at the standard width")
        precondition(VMacSidebarWidth.restored(180) == 180 && VMacSidebarWidth.restored(96) == 96)
        precondition(VMacSidebarWidth.restored(20) == 64 && VMacSidebarWidth.restored(400) == 260, "a saved width out of range is brought back in")
        precondition(VMacSidebarWidth.widest(in: 1280) == 260 && VMacSidebarWidth.widest(in: 820) == 220, "the page keeps 600 for itself")
        precondition(VMacSidebarWidth.remembers(64) && VMacSidebarWidth.remembers(260))
        precondition(!VMacSidebarWidth.remembers(63.5) && !VMacSidebarWidth.remembers(261), "a width the divider cannot reach is not saved")
        // Guests besides the first one can be moved to the Trash, and put back.
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("vmac-slots-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("trash")
        let slotSuite = "vmac.tests.slots.\(UUID().uuidString)"
        let slotStore = UserDefaults(suiteName: slotSuite)!
        defer { try? files.removeItem(at: home); slotStore.removePersistentDomain(forName: slotSuite) }
        let slots = VMacGuestSlots(root: home.appendingPathComponent(".vmac"), defaults: slotStore)
        slotStore.set(["00af2908": "测试客机", "11bb2233": "未启动过"], forKey: VMacGuestSlots.namesKey)
        let folder = slots.folder("00af2908")
        try! files.createDirectory(at: folder.appendingPathComponent("state"), withIntermediateDirectories: true)
        try! Data(count: 4096).write(to: folder.appendingPathComponent("state/disk"))
        try! files.createDirectory(at: bin, withIntermediateDirectories: true)
        let toBin: (URL) throws -> Void = { try files.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) }
        struct Refused: Error {}

        precondition(!slots.removable("default", active: "00af2908"), "the first guest holds the shared account and the other guests")
        precondition(!slots.removable("00af2908", active: "00af2908"), "the guest in use stays")
        precondition(!slots.removable("../../etc", active: "default") && !slots.removable("00AF2908", active: "default"), "only an id VMac made can name a folder to remove")
        precondition(!slots.removable("deadbeef", active: "default"), "a guest VMac does not list is not removed")
        precondition(slots.removable("00af2908", active: "default") && slots.removable("11bb2233", active: "default"))
        precondition(slots.size("00af2908") >= 4096 && slots.size("11bb2233") == 0)

        do { try slots.remove("00af2908", active: "00af2908", trash: toBin); preconditionFailure("the guest in use was removed") } catch {}
        do { try slots.remove("00af2908", active: "default", trash: { _ in throw Refused() }); preconditionFailure("a refused move went unreported") } catch {}
        precondition(slots.names["00af2908"] == "测试客机" && files.fileExists(atPath: folder.appendingPathComponent("state/disk").path), "a failed move leaves the guest listed and whole")
        precondition(!files.fileExists(atPath: folder.appendingPathComponent(VMacGuestSlots.nameFile).path))

        // A controller that has not finished closing still holds the guest's lock.
        let lock = folder.appendingPathComponent("control.lock")
        files.createFile(atPath: lock.path, contents: nil)
        let held = open(lock.path, O_RDWR)
        precondition(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0 && slots.busy("00af2908"))
        do { try slots.remove("00af2908", active: "default", trash: toBin); preconditionFailure("a guest still closing was removed") } catch {}
        close(held)
        precondition(!slots.busy("00af2908") && !slots.busy("11bb2233"))

        try! slots.remove("00af2908", active: "default", trash: toBin)
        precondition(slots.names["00af2908"] == nil && !files.fileExists(atPath: folder.path))
        precondition(files.fileExists(atPath: bin.appendingPathComponent("00af2908/state/disk").path), "the guest went to the Trash whole")
        // A guest that was never opened has no folder; only its name goes.
        try! slots.remove("11bb2233", active: "default", trash: toBin)
        precondition(slots.names.isEmpty)

        // Put back from the Trash, the guest is listed again; a name taken meanwhile gets a number.
        slotStore.set(["22cc3344": "测试客机"], forKey: VMacGuestSlots.namesKey)
        try! files.moveItem(at: bin.appendingPathComponent("00af2908"), to: folder)
        slots.adoptRestored()
        precondition(slots.names["00af2908"] == "测试客机 2" && slots.names["22cc3344"] == "测试客机")
        precondition(!files.fileExists(atPath: folder.appendingPathComponent(VMacGuestSlots.nameFile).path))
        // A folder VMac did not remove is left alone.
        try! files.createDirectory(at: slots.folder("33dd4455"), withIntermediateDirectories: true)
        slots.adoptRestored()
        precondition(slots.names["33dd4455"] == nil && slots.names.count == 2)
        print("VMac shell state, status, toast, full screen, menu key, sidebar width and guest removal checks passed")
    }
}
