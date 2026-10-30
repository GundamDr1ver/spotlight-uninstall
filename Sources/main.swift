import AppKit
import ApplicationServices
import ServiceManagement

let writableRoots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
let searchRoots = writableRoots + [URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices")]
let spotlightIDs = ["com.apple.Spotlight", "com.apple.campo"]

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func rect(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
func descendants(_ root: AXUIElement) -> [AXUIElement]? {
    var nodes: [AXUIElement] = [], pending = [(root, 0)]
    while let (element, depth) = pending.popLast() {
        guard nodes.count < 1800, depth < 24 else { return nil }
        nodes.append(element)
        pending.append(contentsOf: children(element).map { ($0, depth + 1) })
    }
    return nodes
}

struct Snapshot {
    let query: String
    let title: String
    let row: CGRect
    let window: CGRect
    let hintStart: CGFloat?
    let labelEnd: CGFloat
    var key: String { query + "\n" + title }
}

func readSnapshot() -> Snapshot? {
    guard AXIsProcessTrusted(),
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for id in spotlightIDs {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
            let visible = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) }
            guard !visible.isEmpty else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.2)
            for window in attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                guard let frame = rect(window), frame.width > 200, frame.height > 70,
                      visible.contains(where: { item in
                          guard let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                                let actual = CGRect(dictionaryRepresentation: bounds) else { return false }
                          return abs(actual.minX - frame.minX) < 4 && abs(actual.minY - frame.minY) < 4
                      }),
                      let nodes = descendants(window),
                      let field = nodes.first(where: { string($0, kAXIdentifierAttribute) == "SpotlightSearchField" || string($0, kAXSubroleAttribute) == kAXSearchFieldSubrole }),
                      !(string(field, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { continue }
                let appRows = nodes.filter {
                    let identifier = string($0, kAXIdentifierAttribute)
                    return string($0, kAXRoleAttribute) == kAXCellRole && identifier.contains("ResultCell") && identifier.contains("Bundle:com.apple.applications")
                }
                guard appRows.count == 1, let row = appRows.first, let rowFrame = rect(row),
                      frame.contains(rowFrame.insetBy(dx: 3, dy: 3)), let contents = descendants(row),
                      let titleNode = contents.first(where: { string($0, kAXRoleAttribute) == kAXStaticTextRole && !["tab", "⇥"].contains(string($0, kAXValueAttribute).lowercased()) }),
                      let titleRect = rect(titleNode) else { continue }
                // shortcut: depends on Spotlight's accessibility identifiers; recheck after macOS UI changes.
                let title = string(titleNode, kAXValueAttribute)
                guard !title.isEmpty else { continue }
                let hint = contents.filter { string($0, kAXIdentifierAttribute) == "inline-button" || string($0, kAXValueAttribute).lowercased() == "tab" }.compactMap { rect($0)?.minX }.min()
                let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15)]).width
                return Snapshot(query: string(field, kAXValueAttribute), title: title, row: rowFrame, window: frame, hintStart: hint, labelEnd: titleRect.minX + min(titleRect.width, textWidth))
            }
        }
    }
    return nil
}

final class UninstallPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var permissions: PermissionsWindowController?
    private var panel: UninstallPanel!
    private var button: NSButton!
    private var timer: Timer?
    private let worker = DispatchQueue(label: "local.spotlight-uninstall.reader", qos: .utility)
    private var reading = false
    private var confirming = false
    private var catalog = AppCatalog(roots: [])
    private var catalogDate = Date.distantPast
    private var previousKey = ""
    private var stableSince = Date()
    private var target: URL?
    private var snapshot: Snapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginLaunch = isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
        panel = UninstallPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        button = NSButton(title: "卸载", target: self, action: #selector(uninstall))
        button.bezelStyle = .rounded
        button.contentTintColor = .systemRed
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel("卸载此应用并移到废纸篓")
        panel.contentView = button
        if !loginLaunch { showPermissions() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func showPermissions() {
        if permissions == nil { permissions = PermissionsWindowController() }
        permissions?.present()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPermissions()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func hide() { panel.orderOut(nil); target = nil; snapshot = nil; previousKey = "" }

    private func poll() {
        guard !confirming else { return }
        guard AXIsProcessTrusted() else { hide(); return }
        guard !reading else { return }
        reading = true
        worker.async { [self] in
            if Date().timeIntervalSince(catalogDate) > 30 {
                catalog = AppCatalog(roots: searchRoots)
                catalogDate = Date()
            }
            let found = readSnapshot()
            let url = found.flatMap { catalog.resolve($0.title) }
            DispatchQueue.main.async { [self] in
                reading = false
                guard !confirming else { return }
                guard let found, let url, allowedApp(url, roots: writableRoots, ownURL: Bundle.main.bundleURL),
                      FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url), bundle.bundleIdentifier != nil else { hide(); return }
                let key = found.key + url.path
                if previousKey != key {
                    hide(); previousKey = key; stableSince = Date(); return
                }
                guard Date().timeIntervalSince(stableSince) > 0.65 else { return }
                target = url; snapshot = found
                var frame = buttonFrame(row: found.row, labelEnd: found.labelEnd, hintStart: found.hintStart, window: found.window)
                button.title = frame.width > 100 ? "卸载此应用…" : "卸载"
                button.toolTip = "将 \(found.title) 移到废纸篓\n\(url.path)"
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                frame.origin.y = screenTop - frame.maxY
                guard NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) else { hide(); return }
                panel.setFrame(frame, display: true)
                panel.orderFrontRegardless()
            }
        }
    }

    @objc private func uninstall() {
        guard !confirming, let url = target, let expected = snapshot else { return }
        // Re-read before showing confirmation so a changed search cannot reuse a stale button.
        guard let current = readSnapshot(), current.key == expected.key,
              AppCatalog(roots: searchRoots).resolve(current.title) == url,
              allowedApp(url, roots: writableRoots, ownURL: Bundle.main.bundleURL) else { hide(); return }
        confirming = true
        hide()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "卸载“\(expected.title)”？"
        alert.informativeText = "将以下应用移到废纸篓，可从废纸篓恢复。不会清理设置或其他文件。\n\n\(url.path)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到废纸篓")
        defer { confirming = false }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard allowedApp(url, roots: writableRoots, ownURL: Bundle.main.bundleURL),
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { showError("应用路径已改变，请重新搜索。"); return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else { showError("请先退出“\(expected.title)”，再重新搜索并卸载。"); return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            worker.async { [self] in catalogDate = .distantPast }
        } catch { showError("无法移动到废纸篓：\(error.localizedDescription)\n\n\(url.path)") }
    }
    private func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = "未卸载应用"; alert.informativeText = text; alert.runModal()
    }
}

if CommandLine.arguments.contains("--inspect") {
    print("Version:", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")
    print("Login item:", SMAppService.mainApp.status.rawValue)
    print("Accessibility:", AXIsProcessTrusted())
    if let found = readSnapshot() {
        print("Unique app:", found.title, "row:", found.row, "window:", found.window)
        print("Resolved:", AppCatalog(roots: searchRoots).resolve(found.title)?.path ?? "ambiguous or missing")
        print("Button:", buttonFrame(row: found.row, labelEnd: found.labelEnd, hintStart: found.hintStart, window: found.window))
    } else { print("No single visible app result") }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
