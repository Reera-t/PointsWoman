import Foundation
import SystemConfiguration
import Darwin
import MachO

public enum ScopedDirectRoute {
    public struct Snapshot: Codable {
        public let interface: String
        public let gateway: String
        public init(interface: String, gateway: String) { self.interface = interface; self.gateway = gateway }
    }
    public static var recoveryURL: URL { Storage.directory.appendingPathComponent("route-recovery.json") }
    private static func info(_ interface: String, run: (String, [String]) throws -> String) -> (String, String)? {
        guard let text = try? run("/sbin/route", ["-n", "get", "-ifscope", interface, "default"]), text.contains("IFSCOPE") else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        guard let found = ProxySettings.value("interface", in: lines), found == interface,
              let gateway = ProxySettings.value("gateway", in: lines) else { return nil }
        return (found, gateway)
    }
    public static func needsRepair(interface: String, run: (String, [String]) throws -> String = Command.run) -> Bool {
        info(interface, run: run) == nil
    }
    @discardableResult
    public static func repair(interface: String, recovery: URL = recoveryURL,
                              run: (String, [String]) throws -> String = Command.run,
                              authorize: (String) throws -> Void = Command.administrator) throws -> Bool {
        guard interface.hasPrefix("en"), interface.dropFirst(2).allSatisfy(\.isNumber), interface.count > 2 else {
            throw PWError.message("Route repair requires a physical en-number interface.")
        }
        if info(interface, run: run) != nil { return false } // Preserve existing routes; never claim ownership.
        if FileManager.default.fileExists(atPath: recovery.path) {
            let old = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: recovery))
            guard old.interface == interface else { throw PWError.message("Restore the previously repaired interface before switching interfaces.") }
        }
        let gateway = try run("/usr/sbin/ipconfig", ["getoption", interface, "router"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        guard inet_pton(AF_INET, gateway, &address) == 1 else { throw PWError.message("Cannot determine physical IPv4 gateway from DHCP. No routes changed.") }
        try Storage.save(Snapshot(interface: interface, gateway: gateway), to: recovery)
        let shell = ["/sbin/route", "-n", "add", "-ifscope", interface, "default", gateway].map(Command.shellQuote).joined(separator: " ")
        try authorize(shell)
        guard let current = info(interface, run: run), current.1 == gateway else {
            throw PWError.message("Scoped route repair could not be verified. Recovery snapshot retained.")
        }
        return true
    }
    public static func restore(recovery: URL = recoveryURL,
                               run: (String, [String]) throws -> String = Command.run,
                               authorize: (String) throws -> Void = Command.administrator) throws {
        guard FileManager.default.fileExists(atPath: recovery.path) else { return }
        let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: recovery))
        if let current = info(saved.interface, run: run) {
            guard current.1 == saved.gateway else { throw PWError.message("Scoped route changed outside PointsWoman. No route removed; snapshot retained.") }
            try authorize(["/sbin/route", "-n", "delete", "-ifscope", saved.interface, "default", saved.gateway].map(Command.shellQuote).joined(separator: " "))
            guard info(saved.interface, run: run) == nil else { throw PWError.message("Scoped route removal could not be verified.") }
        }
        try FileManager.default.removeItem(at: recovery)
    }
}

public enum Command {
    public static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"; env["LANG"] = "C"
        process.environment = env
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.contains("AuthorizationCreate() failed"), !text.contains("** Error") else {
            throw PWError.message(text.isEmpty ? "Command failed (\(process.terminationStatus))." : text)
        }
        return text
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func administrator(_ shell: String) throws {
        // Try passwordless sudo first
        if (try? run("/usr/bin/sudo", ["-n", "/bin/sh", "-c", shell])) != nil {
            return
        }
        // AppleScript string escaping is separate from shell argument quoting.
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        _ = try run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}

public struct ProxySnapshot: Codable, Equatable {
    public let service: String
    public let previousURL: String
    public let previousEnabled: Bool
    public let installedURL: String
    public let createdAt: Date
}

public enum ProxySettings {
    private static let tool = "/usr/sbin/networksetup"
    public static func vpnRecoveryURL(primary: URL = Storage.recoveryURL) -> URL {
        primary.deletingLastPathComponent().appendingPathComponent("proxy-recovery-v2box.json")
    }
    public static func hasManagedRecovery(primary: URL = Storage.recoveryURL,
                                          run: (String, [String]) throws -> String = Command.run) -> Bool {
        if [primary, vpnRecoveryURL(primary: primary)].contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return true
        }
        let proxy = (try? run("/usr/sbin/scutil", ["--proxy"])) ?? ""
        return proxy.contains("ProxyAutoConfigEnable : 1") && proxy.contains("127.0.0.1")
    }
    private static func v2boxConnected(run: (String, [String]) throws -> String) throws -> Bool {
        // Never request extended VPN status: it may contain profile credentials.
        try run("/usr/sbin/scutil", ["--nc", "list"]).components(separatedBy: .newlines)
            .contains { $0.contains("(Connected)") && $0.contains("\"V2BOX\"") }
    }
    private static func effectivePACMatches(_ url: String, run: (String, [String]) throws -> String) throws -> Bool {
        let lines = try run("/usr/sbin/scutil", ["--proxy"]).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.contains("ProxyAutoConfigEnable : 1") && lines.contains("ProxyAutoConfigURLString : \(url)")
    }
    private static func connectedRecovery(primary: URL) -> URL {
        if FileManager.default.fileExists(atPath: primary.path), let first = try? snapshot(at: primary), first.service == "V2BOX" {
            return primary
        }
        return vpnRecoveryURL(primary: primary)
    }
    public static func needsVPNProxySync(port: UInt16, primary: URL = Storage.recoveryURL,
                                        run: (String, [String]) throws -> String = Command.run) throws -> Bool {
        guard try v2boxConnected(run: run) else { return false }
        let recovery = connectedRecovery(primary: primary)
        guard FileManager.default.fileExists(atPath: recovery.path) else { return true }
        let url = "http://127.0.0.1:\(port)/proxy.pac"
        let state = try run(tool, ["-getautoproxyurl", "V2BOX"])
        let effective = try effectivePACMatches(url, run: run)
        return value("URL", in: state) != url || value("Enabled", in: state) != "Yes" || !effective
    }
    @discardableResult
    public static func synchronizeVPNProxy(port: UInt16, primary: URL = Storage.recoveryURL,
                                           run: (String, [String]) throws -> String = Command.run,
                                           authorize: (String) throws -> Void = Command.administrator) throws -> Bool {
        guard try needsVPNProxySync(port: port, primary: primary, run: run) else { return false }
        let url = "http://127.0.0.1:\(port)/proxy.pac"
        if FileManager.default.fileExists(atPath: primary.path), let existing = try? snapshot(at: primary) {
            guard existing.installedURL == url else { throw PWError.message("Saved PAC port differs from this proxy. Restore settings before changing ports.") }
        }
        let recovery = connectedRecovery(primary: primary)
        if !FileManager.default.fileExists(atPath: recovery.path) {
            let state = try run(tool, ["-getautoproxyurl", "V2BOX"])
            let currentURL = value("URL", in: state)
            let enabled = value("Enabled", in: state)
            if currentURL == url && enabled == "Yes" {
                let snapshot = ProxySnapshot(service: "V2BOX", previousURL: "(null)", previousEnabled: false,
                                             installedURL: url, createdAt: Date())
                try Storage.save(snapshot, to: recovery)
            } else {
                try apply(service: "V2BOX", port: port, recovery: recovery, run: run, authorize: authorize)
            }
        } else {
            let saved = try snapshot(at: recovery)
            let state = try run(tool, ["-getautoproxyurl", "V2BOX"])
            guard saved.service == "V2BOX", saved.installedURL == url,
                  let currentURL = value("URL", in: state), let enabled = value("Enabled", in: state),
                  currentURL == saved.installedURL || (currentURL == saved.previousURL && enabled == (saved.previousEnabled ? "Yes" : "No")) else {
                throw PWError.message("V2BOX PAC changed outside PointsWoman. Existing settings preserved.")
            }
            for mode in ["-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy", "-getproxyautodiscovery"] {
                let output = try run(tool, [mode, "V2BOX"])
                guard value("Enabled", in: output) != "Yes", !output.contains(": On") else {
                    throw PWError.message("V2BOX has another active proxy. Existing settings preserved.")
                }
            }
            try authorize("set -e; " + [command(["-setautoproxyurl", "V2BOX", url]), command(["-setautoproxystate", "V2BOX", "on"])].joined(separator: "; "))
        }
        let verified = try run(tool, ["-getautoproxyurl", "V2BOX"])
        guard value("URL", in: verified) == url, value("Enabled", in: verified) == "Yes",
              try effectivePACMatches(url, run: run) else { throw PWError.message("V2BOX PAC could not be verified. Recovery settings retained.") }
        return true
    }
    public static func restoreManaged(primary: URL = Storage.recoveryURL,
                                       run: (String, [String]) throws -> String = Command.run,
                                       authorize: (String) throws -> Void = Command.administrator,
                                       clearUnsetCommand: (String, String) throws -> String = ProxySettings.clearUnsetPACCommand) throws {
        let recoveries = [vpnRecoveryURL(primary: primary), primary].filter { FileManager.default.fileExists(atPath: $0.path) }
        if recoveries.isEmpty {
            let proxy = (try? run("/usr/sbin/scutil", ["--proxy"])) ?? ""
            if proxy.contains("ProxyAutoConfigEnable : 1") && proxy.contains("127.0.0.1") {
                let services = (try? run(tool, ["-listallnetworkservices"]).components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("*") }) ?? ["Wi-Fi", "V2BOX"]
                var commands: [String] = []
                for s in services {
                    let state = (try? run(tool, ["-getautoproxyurl", s])) ?? ""
                    if value("Enabled", in: state) == "Yes" && value("URL", in: state)?.contains("127.0.0.1") == true {
                        commands.append(command(["-setautoproxystate", s, "off"]))
                        if let url = value("URL", in: state), let clear = try? clearUnsetCommand(s, url) {
                            commands.append("(\(clear) || true)")
                        }
                    }
                }
                if !commands.isEmpty {
                    try authorize("set -e; " + commands.joined(separator: "; "))
                }
            }
            return
        }

        var allCommands: [String] = []
        var toVerify: [(URL, ProxySnapshot)] = []

        for recovery in recoveries {
            guard let saved = try? snapshot(at: recovery) else { continue }
            toVerify.append((recovery, saved))
            allCommands.append(command(["-setautoproxystate", saved.service, "off"]))
            if ["(null)", ""].contains(saved.previousURL) {
                if let clear = try? clearUnsetCommand(saved.service, saved.installedURL) {
                    allCommands.append("(\(clear) || true)")
                }
            } else {
                allCommands.append(command(["-setautoproxyurl", saved.service, saved.previousURL]))
            }
            allCommands.append(command(["-setautoproxystate", saved.service, saved.previousEnabled ? "on" : "off"]))
        }

        let routeURL = ScopedDirectRoute.recoveryURL
        if FileManager.default.fileExists(atPath: routeURL.path),
           let routeSnap = try? JSONDecoder().decode(ScopedDirectRoute.Snapshot.self, from: Data(contentsOf: routeURL)) {
            allCommands.append(["/sbin/route", "-n", "delete", "-ifscope", routeSnap.interface, "default", routeSnap.gateway].map(Command.shellQuote).joined(separator: " ") + " || true")
        }

        if !allCommands.isEmpty {
            try authorize("set -e; " + allCommands.joined(separator: "; "))
        }

        if FileManager.default.fileExists(atPath: routeURL.path) {
            try? FileManager.default.removeItem(at: routeURL)
        }

        for (recovery, saved) in toVerify {
            let restored = (try? run(tool, ["-getautoproxyurl", saved.service])) ?? ""
            let restoredURL = value("URL", in: restored) ?? ""
            let enabled = value("Enabled", in: restored) ?? "No"
            let sameURL = restoredURL == saved.previousURL ||
                          (["", "(null)"].contains(restoredURL) && ["", "(null)"].contains(saved.previousURL)) ||
                          (!saved.previousEnabled && enabled == "No")
            if sameURL && enabled == (saved.previousEnabled ? "Yes" : "No") {
                try? FileManager.default.removeItem(at: recovery)
            } else if enabled == "No" && !saved.previousEnabled {
                try? FileManager.default.removeItem(at: recovery)
            }
        }
    }
    public static func services() throws -> [String] {
        try Command.run(tool, ["-listallnetworkservices"]).components(separatedBy: "\n").dropFirst()
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }
    public static func details(_ service: String) throws -> String {
        try Command.run(tool, ["-getautoproxyurl", service])
    }
    public static func value(_ key: String, in output: String) -> String? {
        let prefix = key + ": "
        return output.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }
    private static func command(_ arguments: [String]) -> String {
        ([tool] + arguments).map(Command.shellQuote).joined(separator: " ")
    }
    @discardableResult
    public static func applyAndSync(service: String, port: UInt16, primary: URL = Storage.recoveryURL,
                                    run: (String, [String]) throws -> String = Command.run,
                                    authorize: (String) throws -> Void = Command.administrator) throws -> Bool {
        let installed = "http://127.0.0.1:\(port)/proxy.pac"
        let available = try run(tool, ["-listallnetworkservices"]).components(separatedBy: "\n").dropFirst()
        guard available.contains(service), !service.hasPrefix("*") else { throw PWError.message("Unknown or disabled network service.") }
        for mode in ["-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy", "-getproxyautodiscovery"] {
            let output = try run(tool, [mode, service])
            if value("Enabled", in: output) == "Yes" || output.contains(": On") {
                throw PWError.message("Existing proxy or auto-discovery is active. PointsWoman will not overwrite it.")
            }
        }
        let primarySnapshot: ProxySnapshot
        if FileManager.default.fileExists(atPath: primary.path) {
            let existing = try ProxySettings.snapshot(at: primary)
            guard existing.installedURL == installed else {
                throw PWError.message("Recovery snapshot already exists. Restore previous settings before enabling again.")
            }
            primarySnapshot = ProxySnapshot(service: service, previousURL: existing.previousURL, previousEnabled: existing.previousEnabled,
                                            installedURL: installed, createdAt: existing.createdAt)
        } else {
            let current = try run(tool, ["-getautoproxyurl", service])
            guard let enabled = value("Enabled", in: current), ["Yes", "No"].contains(enabled), let url = value("URL", in: current) else {
                throw PWError.message("Could not read current automatic proxy settings.")
            }
            guard enabled == "No" || url == installed else { throw PWError.message("An automatic proxy is already enabled. Restore or disable it before using PointsWoman.") }
            primarySnapshot = ProxySnapshot(service: service, previousURL: url == installed ? "(null)" : url, previousEnabled: false,
                                            installedURL: installed, createdAt: Date())
        }
        var commands = [command(["-setautoproxyurl", service, installed]), command(["-setautoproxystate", service, "on"])]
        var savedSnapshots: [(URL, ProxySnapshot)] = [(primary, primarySnapshot)]

        let shouldSyncV2Box = (try? v2boxConnected(run: run)) ?? false
        if shouldSyncV2Box {
            let vpnRecovery = vpnRecoveryURL(primary: primary)
            let vpnSnapshot: ProxySnapshot
            if FileManager.default.fileExists(atPath: vpnRecovery.path), let existing = try? ProxySettings.snapshot(at: vpnRecovery) {
                vpnSnapshot = ProxySnapshot(service: "V2BOX", previousURL: existing.previousURL, previousEnabled: existing.previousEnabled,
                                            installedURL: installed, createdAt: existing.createdAt)
            } else {
                let vpnState = (try? run(tool, ["-getautoproxyurl", "V2BOX"])) ?? ""
                let vpnURL = value("URL", in: vpnState)
                vpnSnapshot = ProxySnapshot(service: "V2BOX", previousURL: vpnURL == installed ? "(null)" : (vpnURL ?? "(null)"),
                                            previousEnabled: false, installedURL: installed, createdAt: Date())
            }
            savedSnapshots.append((vpnRecovery, vpnSnapshot))
            commands.append(command(["-setautoproxyurl", "V2BOX", installed]))
            commands.append(command(["-setautoproxystate", "V2BOX", "on"]))
        }

        for (url, snap) in savedSnapshots {
            try Storage.save(snap, to: url)
        }

        try authorize("set -e; " + commands.joined(separator: "; "))

        let applied = try run(tool, ["-getautoproxyurl", service])
        guard value("URL", in: applied) == installed, value("Enabled", in: applied) == "Yes" else {
            throw PWError.message("Proxy setup could not be verified. Recovery snapshot retained.")
        }
        return true
    }
    public static func apply(service: String, port: UInt16, recovery: URL = Storage.recoveryURL,
                             run: (String, [String]) throws -> String = Command.run,
                             authorize: (String) throws -> Void = Command.administrator) throws {
        let available = try run(tool, ["-listallnetworkservices"]).components(separatedBy: "\n").dropFirst()
        guard available.contains(service), !service.hasPrefix("*") else { throw PWError.message("Unknown or disabled network service.") }
        for mode in ["-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy", "-getproxyautodiscovery"] {
            let output = try run(tool, [mode, service])
            if value("Enabled", in: output) == "Yes" || output.contains(": On") {
                throw PWError.message("Existing proxy or auto-discovery is active. PointsWoman will not overwrite it.")
            }
        }
        let installed = "http://127.0.0.1:\(port)/proxy.pac"
        let chosenSnapshot: ProxySnapshot
        if FileManager.default.fileExists(atPath: recovery.path) {
            let existing = try ProxySettings.snapshot(at: recovery)
            guard existing.installedURL == installed else {
                throw PWError.message("Recovery snapshot already exists. Restore previous settings before enabling again.")
            }
            chosenSnapshot = ProxySnapshot(service: service, previousURL: existing.previousURL, previousEnabled: existing.previousEnabled,
                                           installedURL: installed, createdAt: existing.createdAt)
        } else {
            let current = try run(tool, ["-getautoproxyurl", service])
            guard let enabled = value("Enabled", in: current), ["Yes", "No"].contains(enabled), let url = value("URL", in: current) else {
                throw PWError.message("Could not read current automatic proxy settings.")
            }
            guard enabled == "No" || url == installed else { throw PWError.message("An automatic proxy is already enabled. Restore or disable it before using PointsWoman.") }
            chosenSnapshot = ProxySnapshot(service: service, previousURL: url == installed ? "(null)" : url, previousEnabled: false,
                                           installedURL: installed, createdAt: Date())
        }
        try Storage.save(chosenSnapshot, to: recovery)
        let commands = [command(["-setautoproxyurl", service, installed]), command(["-setautoproxystate", service, "on"])]
        do {
            try authorize("set -e; " + commands.joined(separator: "; "))
            let applied = try run(tool, ["-getautoproxyurl", service])
            guard value("URL", in: applied) == installed, value("Enabled", in: applied) == "Yes" else {
                throw PWError.message("Proxy setup could not be verified. Recovery snapshot retained.")
            }
        } catch {
            // Keep the snapshot even after cancellation: setup may have partially succeeded.
            throw PWError.message("\(error.localizedDescription) Use Restore Settings if setup was interrupted.")
        }
    }
    public static func snapshot(at recovery: URL = Storage.recoveryURL) throws -> ProxySnapshot {
        try JSONDecoder().decode(ProxySnapshot.self, from: Data(contentsOf: recovery))
    }
    public static func restore(recovery: URL = Storage.recoveryURL,
                               run: (String, [String]) throws -> String = Command.run,
                               authorize: (String) throws -> Void = Command.administrator,
                               clearUnsetCommand: (String, String) throws -> String = ProxySettings.clearUnsetPACCommand) throws {
        let saved = try snapshot(at: recovery)
        let current = try run(tool, ["-getautoproxyurl", saved.service])
        guard let currentURL = value("URL", in: current), let enabled = value("Enabled", in: current) else {
            throw PWError.message("Could not inspect current settings. Recovery snapshot retained.")
        }
        guard currentURL == saved.installedURL || (currentURL == saved.previousURL && enabled == (saved.previousEnabled ? "Yes" : "No")) else {
            throw PWError.message("Proxy settings changed outside PointsWoman. Recovery snapshot retained; inspect settings manually.")
        }
        var commands = [command(["-setautoproxystate", saved.service, "off"])]
        // networksetup rejects empty URLs. Remove the key through SCPreferences instead.
        if ["(null)", ""].contains(saved.previousURL) {
            guard !saved.previousEnabled else { throw PWError.message("Invalid recovery snapshot: an unset PAC URL cannot be enabled.") }
            let clear = try clearUnsetCommand(saved.service, saved.installedURL)
            commands.append("(\(clear) || true)")
        } else { commands.append(command(["-setautoproxyurl", saved.service, saved.previousURL])) }
        commands.append(command(["-setautoproxystate", saved.service, saved.previousEnabled ? "on" : "off"]))
        try authorize("set -e; " + commands.joined(separator: "; "))
        let restored = try run(tool, ["-getautoproxyurl", saved.service])
        let restoredURL = value("URL", in: restored) ?? ""
        let sameURL = restoredURL == saved.previousURL ||
                      (["", "(null)"].contains(restoredURL) && ["", "(null)"].contains(saved.previousURL)) ||
                      (!saved.previousEnabled && value("Enabled", in: restored) == "No")
        guard sameURL, value("Enabled", in: restored) == (saved.previousEnabled ? "Yes" : "No") else {
            throw PWError.message("Restoration could not be verified. Recovery snapshot retained.")
        }
        try FileManager.default.removeItem(at: recovery)
    }

    public static func clearUnsetPACCommand(service: String, expectedURL: String) throws -> String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var bytes = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&bytes, &size) == 0 else { throw PWError.message("Cannot locate recovery executable.") }
        let executable = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
        let helper = executable.lastPathComponent == "PointsWoman"
            ? executable.deletingLastPathComponent().appendingPathComponent("pointswomanctl") : executable
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw PWError.message("Recovery helper is missing.") }
        return [helper.path, "__clear-unset-pac", "--service", service, "--expected-url", expectedURL]
            .map(Command.shellQuote).joined(separator: " ")
    }

    /// Internal one-shot recovery helper. No persistent privileged service is installed.
    public static func clearUnsetPAC(service: String, expectedURL: String) throws {
        guard geteuid() == 0 else { throw PWError.message("PAC cleanup requires administrator authorization.") }
        guard let url = URLComponents(string: expectedURL), url.scheme == "http", url.host == "127.0.0.1",
              url.path == "/proxy.pac", let port = url.port, port > 1023, port <= 65535,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PWError.message("Cleanup only accepts a PointsWoman loopback PAC URL.")
        }
        guard let preferences = SCPreferencesCreate(nil, "PointsWoman recovery" as CFString, nil),
              SCPreferencesLock(preferences, true) else { throw PWError.message("Cannot lock network preferences for recovery.") }
        defer { SCPreferencesUnlock(preferences) }
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService],
              let networkService = services.first(where: { (SCNetworkServiceGetName($0) as String?) == service }),
              let proxies = SCNetworkServiceCopyProtocol(networkService, kSCNetworkProtocolTypeProxies),
              var settings = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] else {
            throw PWError.message("Cannot find the selected service's proxy preferences.")
        }
        let key = kSCPropNetProxiesProxyAutoConfigURLString as String
        guard settings[key] as? String == expectedURL else {
            throw PWError.message("PAC URL changed before cleanup. No preferences were removed.")
        }
        settings.removeValue(forKey: key)
        settings[kSCPropNetProxiesProxyAutoConfigEnable as String] = 0
        guard SCNetworkProtocolSetConfiguration(proxies, settings as CFDictionary),
              SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw PWError.message("Could not commit PAC cleanup. Recovery snapshot retained.")
        }
    }
}
