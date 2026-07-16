// gatewayd — privileged helper for GatewayTray.
//
// Runs as root via a LaunchDaemon. Listens on a local Unix-domain socket and
// performs route changes on request. The app that connects holds NO privileges;
// this daemon detects the Wi-Fi / VPN interfaces and gateway ITSELF and only
// accepts a validated list of CIDR networks from the client. All external
// commands run via argv arrays (never a shell), so there is no injection path.
//
// Protocol: one JSON object per connection, newline-terminated, response is one
// JSON object + newline.
//   -> {"cmd":"ping"}
//   <- {"ok":true,"message":"pong"}
//   -> {"cmd":"status"}
//   <- {"ok":true,"wifi":"en0","wifiGateway":"192.168.86.1","tunnel":"utun0",
//       "defaultInterface":"utun0","isWifi":false}
//   -> {"cmd":"apply","networks":["10.0.0.0/8","20.190.0.0/16"]}
//   <- {"ok":true,"message":"...","added":2,"wifi":"en0", ...}

import Foundation
import Darwin

let SOCKET_PATH = ProcessInfo.processInfo.environment["GATEWAYD_SOCKET"] ?? "/var/run/gatewaytray.sock"
let ADMIN_GID: gid_t = 80 // macOS "admin" group
let LOG_PATH = ProcessInfo.processInfo.environment["GATEWAYD_LOG"] ?? "/var/log/gatewaytray.log"
// Records the default route in effect just before an "apply", so "reset" can
// restore it. Lives in /var/run, which is cleared on reboot — appropriate since
// routes are transient anyway.
let PREV_PATH = ProcessInfo.processInfo.environment["GATEWAYD_PREV"] ?? "/var/run/gatewaytray.prev"

// MARK: - Logging

func logLine(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: LOG_PATH) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            FileManager.default.createFile(atPath: LOG_PATH, contents: data)
        }
    }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

// MARK: - Command execution (argv arrays only, never a shell)

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Network detection

/// The primary Wi-Fi interface (e.g. "en0"), detected via networksetup; falls back to en0.
func wifiInterface() -> String {
    let (_, out) = run("/usr/sbin/networksetup", ["-listallhardwareports"])
    let lines = out.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        if lines[i].contains("Hardware Port: Wi-Fi") || lines[i].contains("Hardware Port: AirPort") {
            // The device line follows the hardware-port line.
            if i + 1 < lines.count, let r = lines[i + 1].range(of: "Device: ") {
                return String(lines[i + 1][r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        i += 1
    }
    return "en0"
}

/// All IPv4 default routes as (gateway, interface) pairs.
func defaultRoutes() -> [(gateway: String, iface: String)] {
    let (_, out) = run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
    var result: [(String, String)] = []
    for line in out.components(separatedBy: "\n") {
        let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if cols.count >= 2, cols[0] == "default" {
            let iface = cols.last ?? ""
            result.append((cols[1], iface))
        }
    }
    return result
}

/// Interface of the single active default route (what `route get default` reports).
func activeDefaultInterface() -> String {
    let (_, out) = run("/sbin/route", ["-n", "get", "default"])
    for line in out.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("interface:") {
            return t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
        }
    }
    return ""
}

/// Gateway IP for the Wi-Fi interface's default route.
func wifiGateway(_ wifiIf: String) -> String? {
    return defaultRoutes().first(where: { $0.iface == wifiIf })?.gateway
}

/// The single active default route's gateway and interface (from `route get default`).
func activeDefault() -> (gateway: String, iface: String) {
    let (_, out) = run("/sbin/route", ["-n", "get", "default"])
    var gw = "", iface = ""
    for line in out.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("gateway:") {
            gw = t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
        } else if t.hasPrefix("interface:") {
            iface = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
        }
    }
    return (gw, iface)
}

/// The VPN tunnel interface to route networks through: a non-Wi-Fi default-route
/// interface if present, otherwise the first utunN carrying an IPv4 address.
func tunnelInterface(_ wifiIf: String) -> String? {
    if let t = defaultRoutes().first(where: { $0.iface != wifiIf && !$0.iface.isEmpty })?.iface {
        return t
    }
    let (_, ifs) = run("/sbin/ifconfig", ["-l"])
    for name in ifs.split(separator: " ").map(String.init) where name.hasPrefix("utun") {
        let (_, detail) = run("/sbin/ifconfig", [name])
        if detail.contains("inet ") { return name }
    }
    return nil
}

// MARK: - CIDR validation

func isValidCIDR(_ s: String) -> Bool {
    let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { return false }
    let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    for o in octets {
        guard let v = Int(o), v >= 0, v <= 255, String(v) == String(o) else { return false }
    }
    return true
}

// MARK: - Operations

func currentState() -> [String: Any] {
    let wifi = wifiInterface()
    let def = activeDefaultInterface()
    return [
        "ok": true,
        "wifi": wifi,
        "wifiGateway": wifiGateway(wifi) ?? "",
        "tunnel": tunnelInterface(wifi) ?? "",
        "defaultInterface": def,
        "isWifi": def == wifi,
    ]
}

func applyRoutes(_ networks: [String]) -> [String: Any] {
    // Validate every network before touching the routing table.
    let invalid = networks.filter { !isValidCIDR($0) }
    if !invalid.isEmpty {
        return ["ok": false, "error": "invalid network(s): \(invalid.joined(separator: ", "))"]
    }

    let wifi = wifiInterface()
    guard let gw = wifiGateway(wifi) else {
        return ["ok": false, "error": "could not determine Wi-Fi (\(wifi)) gateway — is Wi-Fi connected?"]
    }
    let tunnel = tunnelInterface(wifi)

    // Remember the current (pre-fix) default so "reset" can restore it — but only
    // when it isn't already Wi-Fi, so we never clobber the recorded VPN route.
    let before = activeDefault()
    if before.iface != wifi, !before.gateway.isEmpty,
       let data = try? JSONSerialization.data(withJSONObject: ["gateway": before.gateway, "interface": before.iface]) {
        try? data.write(to: URL(fileURLWithPath: PREV_PATH))
    }

    var added = 0
    var notes: [String] = []
    if let tun = tunnel {
        for net in networks {
            let (st, _) = run("/sbin/route", ["-n", "add", "-net", net, "-interface", tun])
            if st == 0 { added += 1 }
        }
        notes.append("routed \(added)/\(networks.count) network(s) via \(tun)")
    } else if !networks.isEmpty {
        notes.append("no VPN tunnel interface found — skipped network routes")
    }

    // Reset the default route to the Wi-Fi gateway.
    run("/sbin/route", ["-n", "delete", "default"])
    let (st, out) = run("/sbin/route", ["-n", "add", "default", gw])
    if st != 0 {
        logLine("apply: failed to set default via \(gw): \(out)")
        return ["ok": false, "error": "failed to set default gateway to \(gw)"]
    }
    notes.append("default gateway -> \(gw) (\(wifi))")
    logLine("apply: \(notes.joined(separator: "; "))")

    var state = currentState()
    state["message"] = notes.joined(separator: "; ")
    state["added"] = added
    return state
}

/// Restore the default route to what it was before the last apply (the VPN/original
/// route). Falls back to any live utun default route if nothing was recorded.
func resetRoutes() -> [String: Any] {
    var gw = "", iface = ""
    if let data = FileManager.default.contents(atPath: PREV_PATH),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        gw = (obj["gateway"] as? String) ?? ""
        iface = (obj["interface"] as? String) ?? ""
    }
    if gw.isEmpty, let t = defaultRoutes().first(where: { $0.iface.hasPrefix("utun") }) {
        gw = t.gateway
        iface = t.iface
    }
    guard !gw.isEmpty else {
        return ["ok": false, "error": "no previous/VPN default route found to restore (VPN may be down)"]
    }

    run("/sbin/route", ["-n", "delete", "default"])
    let (st, out) = run("/sbin/route", ["-n", "add", "default", gw])
    if st != 0 {
        logLine("reset: failed to restore default via \(gw): \(out)")
        return ["ok": false, "error": "failed to restore default gateway to \(gw)"]
    }
    logLine("reset: default -> \(gw) (\(iface.isEmpty ? "original" : iface))")

    var state = currentState()
    state["message"] = "default gateway restored -> \(gw)\(iface.isEmpty ? "" : " (\(iface))")"
    return state
}

// MARK: - Request handling

func jsonLine(_ dict: [String: Any]) -> Data {
    let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{\"ok\":false}".utf8)
    return data + Data("\n".utf8)
}

func processRequest(_ data: Data) -> Data {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cmd = obj["cmd"] as? String else {
        return jsonLine(["ok": false, "error": "malformed request"])
    }
    switch cmd {
    case "ping":
        return jsonLine(["ok": true, "message": "pong"])
    case "status":
        return jsonLine(currentState())
    case "apply":
        let nets = (obj["networks"] as? [String]) ?? []
        return jsonLine(applyRoutes(nets))
    case "reset":
        return jsonLine(resetRoutes())
    default:
        return jsonLine(["ok": false, "error": "unknown cmd: \(cmd)"])
    }
}

// MARK: - Unix socket server

func handleClient(_ fd: Int32) {
    var buf = [UInt8](repeating: 0, count: 65536)
    var request = Data()
    // Read until newline or EOF.
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        request.append(contentsOf: buf[0..<n])
        if buf[0..<n].contains(0x0A) { break }
    }
    guard !request.isEmpty else { return }
    let response = processRequest(request)
    response.withUnsafeBytes { raw in
        _ = write(fd, raw.baseAddress, response.count)
    }
}

func startServer() -> Never {
    unlink(SOCKET_PATH)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { logLine("socket() failed: \(errno)"); exit(1) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(SOCKET_PATH.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < capacity else { logLine("socket path too long"); exit(1) }
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = b }
            dst[pathBytes.count] = 0
        }
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
    }
    guard bindResult == 0 else { logLine("bind() failed: \(errno)"); exit(1) }

    // Restrict access to root + admin group (only admins may change routing).
    if geteuid() == 0 {
        chown(SOCKET_PATH, 0, ADMIN_GID)
    }
    chmod(SOCKET_PATH, 0o660)

    guard listen(fd, 8) == 0 else { logLine("listen() failed: \(errno)"); exit(1) }
    logLine("gatewayd listening on \(SOCKET_PATH) (euid=\(geteuid()))")

    while true {
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        handleClient(client)
        close(client)
    }
}

startServer()
