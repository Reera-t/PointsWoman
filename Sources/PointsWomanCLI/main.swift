import Foundation
import Darwin
import AppKit
import PointsWomanCore

let help = """
PointsWoman — selected-domain VPN bypass for macOS

  pointswomanctl doctor
  pointswomanctl serve [--interface en0] [--port 17839] [--domain example.com ...] [--duration seconds]
  pointswomanctl serve-apps [--interface en0] [--app-port 17840]
  pointswomanctl apps list | discover
  pointswomanctl apps add --app /Applications/Mattermost.app
  pointswomanctl apps remove --app /Applications/Mattermost.app
  pointswomanctl apps launch --app /Applications/Mattermost.app [--app-port 17840]
  pointswomanctl pac [--interface en0] [--port 17839] [--domain example.com ...]
  pointswomanctl apply --service Wi-Fi [--port 17839]
  pointswomanctl restore
  pointswomanctl snapshot
  pointswomanctl setup-sudo
  pointswomanctl install-cli [--directory ~/.local/bin]
  pointswomanctl gui open | quit
  pointswomanctl repair-route --interface en0
  pointswomanctl restore-route
  pointswomanctl sync-vpn [--port 17839]

Options: --config path, --apps-config path, --subdomains (include subdomains of all supplied domains).
Default domains: chat.example.com, app.example.com. Default listener: 127.0.0.1:17839.
serve does not change network settings. apply/restore show macOS administrator prompt.
Keep proxy running while PAC is enabled. After a crash, run restore or reopen app.
DNS uses system resolver; calls/UDP and arbitrary-app bypass are outside v1.
serve-apps accepts all domains for selected proxy-capable apps. Quit app before apps launch.
Use pointswoman as a shorter alias after install-cli. CLI works without the menu-bar app.
"""

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var action = arguments.first ?? "help"
    if action == "apps" {
        guard arguments.count > 1 else { throw PWError.message("Use apps list, discover, add, remove, or launch.") }
        action = "apps-" + arguments.remove(at: 1)
    }
    if action == "gui" {
        guard arguments.count > 1 else { throw PWError.message("Use gui open or gui quit.") }
        action = "gui-" + arguments.remove(at: 1)
    }
    if ["help", "--help", "-h"].contains(action) { print(help); exit(0) }
    var options: [String: [String]] = [:]
    var includeSubdomains = false
    var index = 1
    let accepted = ["--interface", "--port", "--domain", "--duration", "--config", "--service", "--app", "--app-port", "--apps-config", "--directory", "--expected-url"]
    while index < arguments.count {
        let key = arguments[index]
        if key == "--subdomains" { includeSubdomains = true; index += 1; continue }
        guard accepted.contains(key), index + 1 < arguments.count else { throw PWError.message("Unknown or incomplete option: \(key)") }
        options[key, default: []].append(arguments[index + 1]); index += 2
    }
    let configURL = options["--config"]?.last.map { URL(fileURLWithPath: $0) } ?? Storage.configURL
    var config = ["serve", "serve-apps", "pac", "apply"].contains(action) ? try Storage.load(from: configURL) : Configuration()
    let appsURL = options["--apps-config"]?.last.map { URL(fileURLWithPath: $0) } ?? ApplicationSettings.url
    if let name = options["--interface"]?.last { config.interface = name }
    if let port = options["--port"]?.last {
        guard let parsed = UInt16(port), parsed > 1023 else { throw PWError.message("Invalid port.") }
        config.port = parsed
    }
    if let domains = options["--domain"] { config.rules = try domains.map { try DomainRule($0, includeSubdomains: includeSubdomains) } }
    else if includeSubdomains { config.rules = try config.rules.map { try DomainRule($0.host, includeSubdomains: true) } }
    switch action {
    case "doctor":
        print("PointsWoman diagnostics — no settings changed")
        print("Physical interface candidates:")
        for item in NetworkInterface.list() { print("  \(item.name): \(item.up ? "up" : "down"), index \(item.index)") }
        print("\nSystem DNS remains in use. No VPN bypass has been verified.")
        for (tool, args) in [("/usr/sbin/scutil", ["--proxy"]), ("/usr/sbin/scutil", ["--nc", "list"]), ("/usr/sbin/networksetup", ["-listnetworkserviceorder"])] {
            do { print("\n\(tool) \(args.joined(separator: " "))\n\(try Command.run(tool, args))") }
            catch { print("\nDiagnostic unavailable: \(error.localizedDescription)") }
        }
        if FileManager.default.fileExists(atPath: Storage.recoveryURL.path) { print("\nRecovery snapshot exists. Run pointswomanctl restore before enabling again.") }
    case "pac":
        try config.validate(); print(config.pac())
    case "serve", "serve-apps":
        if action == "serve-apps" {
            let settings = try ApplicationSettings.load(from: appsURL)
            guard let port = UInt16(options["--app-port"]?.last ?? String(settings.port)), port > 1023 else { throw PWError.message("Invalid application proxy port.") }
            config.port = port
        }
        let server = ProxyServer(configuration: config, allowsAllDomains: action == "serve-apps")
        try server.start()
        print("PointsWoman listening on 127.0.0.1:\(server.boundPort); bound egress \(config.interface)")
        print(action == "serve-apps" ? "Application proxy accepts all destinations on loopback; use apps launch in another terminal." : "PAC: http://127.0.0.1:\(server.boundPort)/proxy.pac")
        print("Proxy only. System settings unchanged. Connection success is not proof of bypass.")
        fflush(stdout)
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let stop: () -> Void = { server.stop(); exit(0) }
        interrupt.setEventHandler(handler: stop); terminate.setEventHandler(handler: stop)
        interrupt.resume(); terminate.resume()
        if let text = options["--duration"]?.last {
            guard let duration = Double(text), duration > 0, duration.isFinite else { throw PWError.message("Invalid duration.") }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stop)
        }
        dispatchMain()
    case "apply":
        guard let service = options["--service"]?.last else { throw PWError.message("--service is required.") }
        // Require a responding PointsWoman listener before modifying system settings.
        let health = try Command.run("/usr/bin/curl", ["--noproxy", "*", "--fail", "--silent", "--max-time", "3", "http://127.0.0.1:\(config.port)/health"])
        guard health.hasPrefix("PointsWoman running;") else { throw PWError.message("Start PointsWoman proxy first.") }
        try ProxySettings.apply(service: service, port: config.port)
        try ProxySettings.synchronizeVPNProxy(port: config.port)
        print("PAC enabled for \(service). Restart browser/Mattermost connections. Egress remains unverified.")
    case "restore":
        try ProxySettings.restoreManaged()
        try ScopedDirectRoute.restore()
        print("Previous proxy settings and owned scoped routes restored and verified.")
    case "repair-route":
        let added = try ScopedDirectRoute.repair(interface: config.interface)
        print(added ? "Physical IPv4 scoped route repaired; normal VPN default unchanged. Use restore-route to remove it." : "Physical scoped route already exists; no changes made.")
    case "sync-vpn":
        let changed = try ProxySettings.synchronizeVPNProxy(port: config.port)
        print(changed ? "Connected V2Box PAC synchronized and verified." : "No connected VPN PAC update needed. Enable primary network rules first.")
    case "restore-route":
        try ScopedDirectRoute.restore(); print("Owned scoped route restored.")
    case "setup-sudo":
        let user = NSUserName()
        let rule = "\(user) ALL=(ALL) NOPASSWD: /usr/sbin/networksetup, /sbin/route, /bin/sh -c *\n"
        let script = "mkdir -p /etc/sudoers.d && echo \(Command.shellQuote(rule)) > /etc/sudoers.d/pointswoman && chmod 0440 /etc/sudoers.d/pointswoman"
        try Command.administrator(script)
        print("Passwordless sudo configured for \(user) in /etc/sudoers.d/pointswoman. Administrator prompts are no longer needed.")
    case "__clear-unset-pac":
        guard let service = options["--service"]?.last, let url = options["--expected-url"]?.last else {
            throw PWError.message("Recovery service and expected URL are required.")
        }
        try ProxySettings.clearUnsetPAC(service: service, expectedURL: url)
    case "snapshot":
        let saved = try ProxySettings.snapshot()
        print("Service: \(saved.service)\nPrevious PAC enabled: \(saved.previousEnabled)\nInstalled PAC: \(saved.installedURL)\nCreated: \(saved.createdAt)")
    case "apps-list":
        let settings = try ApplicationSettings.load(from: appsURL)
        print("Application proxy port: \(settings.port)")
        for app in settings.applications { print("\(app.name)\t\(app.path)\tHTTP/HTTPS/WebSocket launch adapter") }
        if settings.applications.isEmpty { print("No applications selected. Use apps add --app /path/Application.app") }
    case "apps-discover":
        for app in ApplicationSettings.discover() {
            print("\(app.supportsProxyLaunch ? "SUPPORTED" : "NO ADAPTER")\t\(app.name)\t\(app.path)")
        }
    case "apps-add", "apps-remove":
        guard let path = options["--app"]?.last else { throw PWError.message("--app /path/Application.app is required.") }
        var settings = try ApplicationSettings.load(from: appsURL)
        if action == "apps-add" { try settings.add(SelectedApplication.inspect(path)) }
        else { settings.applications.removeAll { $0.path == URL(fileURLWithPath: path).standardizedFileURL.path } }
        try Storage.save(settings, to: appsURL)
        print("Application selections saved. Use serve-apps, then apps launch.")
    case "apps-launch":
        guard let path = options["--app"]?.last else { throw PWError.message("--app /path/Application.app is required.") }
        let settings = try ApplicationSettings.load(from: appsURL)
        guard let port = UInt16(options["--app-port"]?.last ?? String(settings.port)), port > 1023 else { throw PWError.message("Invalid app proxy port.") }
        let health = try Command.run("/usr/bin/curl", ["--noproxy", "*", "--fail", "--silent", "--max-time", "3", "http://127.0.0.1:\(port)/health"])
        guard health.hasPrefix("PointsWoman running;"), health.contains("scope=applications") else { throw PWError.message("Start serve-apps first; selected-domain proxy is not an application proxy.") }
        try SelectedApplication.inspect(path).launchDirect(port: port)
        print("Application launched with direct HTTP/HTTPS/WebSocket proxy. Other traffic is unchanged.")
    case "install-cli":
        let directory = options["--directory"]?.last.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("pointswoman")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: target.path) {
            guard target.resolvingSymlinksInPath() == executable else { throw PWError.message("A different pointswoman command already exists. It was not overwritten.") }
        } else { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: executable) }
        print("CLI ready: \(target.path)\nKeep original executable at \(executable.path). Add \(directory.path) to PATH if needed.")
    case "gui-quit":
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "local.pointswoman.app")
        guard !applications.isEmpty else { print("PointsWoman GUI is not running."); exit(0) }
        for app in applications {
            guard app.terminate() else { throw PWError.message("GUI could not be asked to quit. Use its Restore settings & stop control.") }
        }
        print("Normal Quit requested. GUI restores saved proxy settings before exiting; administrator approval may be required.")
    case "gui-open":
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        var candidates: [URL] = []
        for _ in 0..<4 {
            candidates.append(directory.appendingPathComponent("PointsWoman.app"))
            if directory.pathExtension == "app" { candidates.append(directory) }
            directory.deleteLastPathComponent()
        }
        let chosen = options["--app"]?.last.map { URL(fileURLWithPath: $0) }
            ?? candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/PointsWoman").path) })
        guard let app = chosen else { throw PWError.message("PointsWoman.app not found. Use gui open --app /path/PointsWoman.app") }
        _ = try Command.run("/usr/bin/open", [app.path])
        print("PointsWoman GUI opened.")
    default: throw PWError.message("Unknown command: \(action). Use --help.")
    }
} catch {
    FileHandle.standardError.write(Data("PointsWoman: \(error.localizedDescription)\n".utf8)); exit(1)
}
