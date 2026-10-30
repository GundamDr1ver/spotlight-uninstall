import AppKit
import ApplicationServices
import ServiceManagement

let repositoryURL = URL(string: "https://github.com/GundamDr1ver/spotlight-uninstall")!

final class PermissionRow: NSStackView {
    let status = NSTextField(labelWithString: "未授权")
    let request = NSButton(title: "请求权限", target: nil, action: nil)

    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 14
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        status.font = .systemFont(ofSize: 12)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        request.bezelStyle = .rounded
        request.target = target
        request.action = action
        request.setAccessibilityLabel("申请" + title + "权限")
        [label, status, request].forEach { addArrangedSubview($0) }
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true
        request.widthAnchor.constraint(equalToConstant: 94).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(granted: Bool, pending: Bool = false, error: String? = nil) {
        status.stringValue = granted ? "已授权" : pending ? "待系统批准" : error == nil ? "未授权" : "申请失败"
        status.textColor = granted ? .systemGreen : .secondaryLabelColor
        status.toolTip = error
        request.isEnabled = !granted
        request.title = granted ? "已授权" : pending ? "前往设置" : "请求权限"
    }
}

final class PermissionsWindowController: NSWindowController {
    private var login: PermissionRow!
    private var accessibility: PermissionRow!
    private var refreshTimer: Timer?
    private var loginError: String?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 258), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.level = .floating
        window.title = "聚焦卸载"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let name = NSTextField(labelWithString: "聚焦卸载")
        name.font = .systemFont(ofSize: 26, weight: .semibold)
        let version = NSTextField(labelWithString: "版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"))
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [name, version])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 6
        let github = NSButton(title: "", target: self, action: #selector(openRepository))
        github.isBordered = false
        if let imageURL = Bundle.main.url(forResource: "GitHub-Mark", withExtension: "png"), let image = NSImage(contentsOf: imageURL) {
            image.isTemplate = true
            github.image = image
        }
        github.imageScaling = .scaleProportionallyDown
        github.toolTip = repositoryURL.absoluteString
        github.setAccessibilityLabel("GitHub 仓库")
        github.widthAnchor.constraint(equalToConstant: 30).isActive = true
        github.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let spacer = NSView()
        let header = NSStackView(views: [heading, spacer, github])
        header.alignment = .centerY
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        login = PermissionRow(title: "开机自启", target: self, action: #selector(requestLogin))
        accessibility = PermissionRow(title: "辅助功能", target: self, action: #selector(requestAccessibility))
        let content = NSStackView(views: [header, login, accessibility])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 22
        content.setCustomSpacing(30, after: header)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            login.widthAnchor.constraint(equalTo: content.widthAnchor),
            accessibility.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.center()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { refreshTimer?.invalidate() }

    func present() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        let state = SMAppService.mainApp.status
        login.update(granted: state == .enabled, pending: state == .requiresApproval, error: loginError)
        accessibility.update(granted: AXIsProcessTrusted())
    }
    @objc private func requestLogin() {
        loginError = nil
        do {
            if SMAppService.mainApp.status != .requiresApproval { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { loginError = error.localizedDescription }
        refresh()
    }
    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        refresh()
    }
    @objc private func openRepository() { NSWorkspace.shared.open(repositoryURL) }
}
