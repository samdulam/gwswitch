// GW Switch — menu-bar indicator + control window.
//
// Shows 🟢 when the default gateway is Wi-Fi, 🟠 otherwise. It reads the routing
// table directly (no privilege needed) for display, and asks the root `gatewayd`
// helper — over a local Unix socket — to actually change routes. The helper is
// what was authorized once at install, so applying routes never prompts again.

import Cocoa

let SOCKET_PATH = "/var/run/gatewaytray.sock"
let POLL_INTERVAL = 3.0

// Per-user config: tunnel networks, one CIDR per line, "#" to disable a line.
let CONFIG_DIR = ("~/Library/Application Support/GatewayTray" as NSString).expandingTildeInPath
let CONFIG_PATH = CONFIG_DIR + "/networks.conf"

let DEFAULT_CONFIG = """
# GW Switch — networks routed through the VPN tunnel.
# One CIDR per line. Prefix a line with # to disable it.
# Clicking the tray icon (or Apply) routes these via the tunnel and
# resets the default gateway back to Wi-Fi.
#
# Replace the examples below with the networks your VPN should carry.

# Private / corporate network (RFC 1918 example)
10.0.0.0/8

# Microsoft Entra ID sign-in (login.microsoftonline.com) — uncomment if needed
# 20.190.0.0/16
# 40.126.0.0/16

# Add your own tunnel networks here, one CIDR per line.
"""

// MARK: - Daemon client

struct DaemonReply {
    let ok: Bool
    let dict: [String: Any]
    var message: String { (dict["message"] as? String) ?? (dict["error"] as? String) ?? "" }
}

/// Send one JSON request to gatewayd and read its JSON reply. Returns nil if the
/// helper isn't installed/running or the socket is unreachable.
func sendToDaemon(_ request: [String: Any]) -> DaemonReply? {
    guard var body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    body.append(0x0A)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(SOCKET_PATH.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < capacity else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = b }
            dst[pathBytes.count] = 0
        }
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addrLen) }
    }
    guard connectResult == 0 else { return nil }

    let ok = body.withUnsafeBytes { write(fd, $0.baseAddress, body.count) }
    guard ok > 0 else { return nil }

    var reply = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        reply.append(contentsOf: buf[0..<n])
        if buf[0..<n].contains(0x0A) { break }
    }
    guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
    return DaemonReply(ok: (obj["ok"] as? Bool) ?? false, dict: obj)
}

// MARK: - Local (unprivileged) helpers

func activeDefaultInterface() -> String {
    let p = Process()
    p.launchPath = "/sbin/route"
    p.arguments = ["-n", "get", "default"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in out.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("interface:") {
            return t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
        }
    }
    return ""
}

/// Wi-Fi interface (e.g. "en0"), detected locally via networksetup; falls back
/// to en0. Cached by the caller — this is not on the periodic path.
func wifiInterfaceLocal() -> String {
    let p = Process()
    p.launchPath = "/usr/sbin/networksetup"
    p.arguments = ["-listallhardwareports"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "en0" }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    let lines = out.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
        if i + 1 < lines.count {
            let dev = lines[i + 1].replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
            if !dev.isEmpty { return dev }
        }
    }
    return "en0"
}

func routingTableText() -> String {
    let p = Process()
    p.launchPath = "/usr/sbin/netstat"
    p.arguments = ["-rn", "-f", "inet"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "(unable to read routing table)" }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func loadConfig() -> String {
    try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
    if let s = try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8) { return s }
    try? DEFAULT_CONFIG.write(toFile: CONFIG_PATH, atomically: true, encoding: .utf8)
    return DEFAULT_CONFIG
}

func saveConfig(_ text: String) {
    try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
    try? text.write(toFile: CONFIG_PATH, atomically: true, encoding: .utf8)
}

/// Enabled CIDRs from the config text (non-empty, non-comment lines).
func enabledNetworks(from text: String) -> [String] {
    text.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

// MARK: - Control window

final class GatewayWindowController: NSWindowController {
    let statusLabel = NSTextField(labelWithString: "")
    let routesView = NSTextView()
    let networksView = NSTextView()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "GW Switch"
        w.center()
        self.init(window: w)
        buildUI()
    }

    private func mono(_ view: NSTextView, editable: Bool) -> NSScrollView {
        view.isEditable = editable
        view.isRichText = false
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = view
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func header(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = NSFont.boldSystemFont(ofSize: 12)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let routesHeader = header("Current routes & default gateway")
        let netsHeader = header("Tunnel networks  (one CIDR per line, # to disable)")
        let routesScroll = mono(routesView, editable: false)
        let netsScroll = mono(networksView, editable: true)

        let applyBtn = NSButton(title: "Apply via Wi-Fi", target: self, action: #selector(apply))
        applyBtn.keyEquivalent = "\r"
        let resetBtn = NSButton(title: "Reset to VPN (original)", target: self, action: #selector(reset))
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let buttons = NSStackView(views: [refreshBtn, saveBtn, resetBtn, applyBtn])
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for v in [statusLabel, routesHeader, routesScroll, netsHeader, netsScroll, buttons] {
            content.addSubview(v)
        }
        let m: CGFloat = 16
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            routesHeader.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: m),
            routesHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),

            routesScroll.topAnchor.constraint(equalTo: routesHeader.bottomAnchor, constant: 6),
            routesScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            routesScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            routesScroll.heightAnchor.constraint(equalToConstant: 240),

            netsHeader.topAnchor.constraint(equalTo: routesScroll.bottomAnchor, constant: m),
            netsHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),

            netsScroll.topAnchor.constraint(equalTo: netsHeader.bottomAnchor, constant: 6),
            netsScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            netsScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            netsScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -m),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
        ])

        networksView.string = loadConfig()
        refresh()
    }

    @objc func refresh() {
        routesView.string = routingTableText()
        let reply = sendToDaemon(["cmd": "status"])
        let iface = activeDefaultInterface()
        if let r = reply, r.ok {
            let wifi = (r.dict["wifi"] as? String) ?? "en0"
            let isWifi = (r.dict["isWifi"] as? Bool) ?? (iface == wifi)
            statusLabel.stringValue = isWifi
                ? "🟢  Default gateway is Wi-Fi (\(wifi))"
                : "🟠  Default gateway is \(iface.isEmpty ? "unknown" : iface) — not Wi-Fi"
        } else {
            statusLabel.stringValue = "⚠️  Helper not reachable — is GW Switch installed? (default: \(iface))"
        }
    }

    @objc func save() {
        saveConfig(networksView.string)
    }

    @objc func apply() {
        save()
        let nets = enabledNetworks(from: networksView.string)
        guard let reply = sendToDaemon(["cmd": "apply", "networks": nets]) else {
            alert("Helper not reachable", "The gatewayd helper isn't installed or running. Reinstall GW Switch.")
            return
        }
        if !reply.ok { alert("Could not apply routes", reply.message) }
        refresh()
    }

    @objc func reset() {
        guard let reply = sendToDaemon(["cmd": "reset"]) else {
            alert("Helper not reachable", "The gatewayd helper isn't installed or running. Reinstall GW Switch.")
            return
        }
        if !reply.ok { alert("Could not reset routes", reply.message) }
        refresh()
    }

    private func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.alertStyle = .warning
        a.runModal()
    }
}

// MARK: - App delegate / menu bar

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var isWifi = false
    var currentInterface = ""
    var wifiIface = "en0"
    var windowController: GatewayWindowController?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        wifiIface = wifiInterfaceLocal()
        update()
        timer = Timer.scheduledTimer(withTimeInterval: POLL_INTERVAL, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func update() {
        currentInterface = activeDefaultInterface()
        // Compare against the locally-detected, cached Wi-Fi interface. This runs
        // every few seconds, so it must NOT call the daemon — doing so made the
        // daemon spawn subprocesses on every tick and eventually exhaust its file
        // descriptors, after which detection failed entirely.
        isWifi = (currentInterface == wifiIface)
        guard let button = statusItem.button else { return }
        button.title = isWifi ? "🟢" : "🟠"
        let desc = currentInterface.isEmpty ? "unknown" : currentInterface
        button.toolTip = isWifi
            ? "Default gateway via Wi-Fi (\(desc))"
            : "Default gateway via \(desc) — click to route via Wi-Fi"
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            showMenu()
        } else if isWifi {
            openWindow()
        } else {
            quickApply()
        }
    }

    func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let head = NSMenuItem(title: isWifi ? "Gateway: Wi-Fi ✓" : "Gateway: \(currentInterface) — not Wi-Fi",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open GW Switch…", action: #selector(openWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Route via Wi-Fi now", action: #selector(quickApply), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Reset to VPN (original)", action: #selector(quickReset), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc func openWindow() {
        if windowController == nil { windowController = GatewayWindowController() }
        windowController?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Fast path from the tray: apply the saved config with no window.
    @objc func quickApply() {
        let nets = enabledNetworks(from: loadConfig())
        guard let reply = sendToDaemon(["cmd": "apply", "networks": nets]) else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Helper not reachable"
            a.informativeText = "The gatewayd helper isn't installed or running. Reinstall GW Switch."
            a.runModal()
            return
        }
        if !reply.ok {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Could not apply routes"
            a.informativeText = reply.message
            a.runModal()
        }
        update()
    }

    /// Fast path from the tray: restore the previous (VPN) default route.
    @objc func quickReset() {
        guard let reply = sendToDaemon(["cmd": "reset"]) else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Helper not reachable"
            a.informativeText = "The gatewayd helper isn't installed or running. Reinstall GW Switch."
            a.runModal()
            return
        }
        if !reply.ok {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Could not reset routes"
            a.informativeText = reply.message
            a.runModal()
        }
        update()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
