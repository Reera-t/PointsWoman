import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PointsWomanCore

final class AppModel: ObservableObject {
    @Published var interface = "en0"
    @Published var port = "17839"
    @Published var domains = "chat.example.com\napp.example.com"
    @Published var subdomains = false
    @Published var service = "Wi-Fi"
    @Published var services = ["Wi-Fi"]
    @Published var interfaces: [String] = []
    @Published var status = "Stopped. Enable only after testing your VPN."
    @Published var lastEvent = "No traffic observed."
    @Published var running = false
    @Published var busy = false
    @Published var recoveryExists = false
    @Published var routeRecoveryExists = false
    @Published var applications: [SelectedApplication] = []
    @Published var appPort = "17840"
    @Published var stats = "0 connections"
    private var server: ProxyServer?
    private var applicationServer: ProxyServer?
    private var timer: Timer?
    private var routeCheckPending = false
    private var routeRepairFailed = false
    private var vpnSyncFailed = false
    private var ticks = 0

    init() {
        do {
            let config = try Storage.load()
            interface = config.interface; port = String(config.port)
            domains = config.rules.map(\.host).joined(separator: "\n")
            subdomains = config.rules.allSatisfy(\.includeSubdomains)
        } catch { status = "Could not load saved configuration: \(error.localizedDescription)" }
        do {
            let settings = try ApplicationSettings.load()
            applications = settings.applications; appPort = String(settings.port)
        } catch { status = "Could not load app selections: \(error.localizedDescription)" }
        refreshInterfaces()
        recoveryExists = ProxySettings.hasManagedRecovery()
        routeRecoveryExists = FileManager.default.fileExists(atPath: ScopedDirectRoute.recoveryURL.path)
        if recoveryExists {
            startLocal()
            status = "Resumed proxy for active network PAC settings. Choose Restore settings & stop to disable."
        }
        DispatchQueue.global().async {
            if let found = try? ProxySettings.services(), !found.isEmpty {
                DispatchQueue.main.async { self.services = found; self.service = found.contains("Wi-Fi") ? "Wi-Fi" : found[0] }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let stats = self.server?.statistics else { return }
            let apps = self.applicationServer?.statistics ?? ProxyStatistics()
            self.stats = "\(stats.active + apps.active) active · \(stats.connected + apps.connected) connected · \(stats.failed + apps.failed) failed"
            self.lastEvent = apps.connected + apps.failed > 0 ? apps.lastEvent : stats.lastEvent
            self.ticks += 1
            if self.ticks % 5 == 0 && !self.busy && !self.routeCheckPending {
                self.routeCheckPending = true
                let name = self.interface
                let proxyPort = self.server!.configuration.port
                DispatchQueue.global().async {
                    let missing = ScopedDirectRoute.needsRepair(interface: name)
                    let needsProxy = (try? ProxySettings.needsVPNProxySync(port: proxyPort)) ?? false
                    DispatchQueue.main.async {
                        self.routeCheckPending = false
                        if self.running && !self.busy {
                            if missing && !self.routeRepairFailed { self.repairRoute() }
                            else if needsProxy && !self.vpnSyncFailed { self.synchronizeVPNProxy() }
                        }
                    }
                }
            }
        }
    }
    func refreshInterfaces() {
        interfaces = NetworkInterface.list().filter(\.up).map(\.name)
        if !interfaces.contains(interface), let first = interfaces.first { interface = first }
    }
    func configuration() throws -> Configuration {
        guard let number = UInt16(port) else { throw PWError.message("Invalid port.") }
        let rules = try domains.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try DomainRule($0, includeSubdomains: subdomains) }
        let config = Configuration(interface: interface, port: number, rules: rules)
        try config.validate()
        guard NetworkInterface.list().contains(where: { $0.name == interface && $0.up }) else {
            throw PWError.message("Choose an active physical interface.")
        }
        return config
    }
    func startLocal() {
        guard !running else { return }
        do {
            let config = try configuration()
            let engine = ProxyServer(configuration: config)
            guard let appsPort = UInt16(appPort), appsPort > 1023, appsPort != config.port else {
                throw PWError.message("Choose different unprivileged ports for website and application proxies.")
            }
            let appEngine = applications.isEmpty ? nil : ProxyServer(configuration: Configuration(interface: config.interface, port: appsPort), allowsAllDomains: true)
            try Storage.save(config, to: Storage.configURL)
            try Storage.save(ApplicationSettings(port: appsPort, applications: applications), to: ApplicationSettings.url)
            try engine.start()
            do { try appEngine?.start() } catch { engine.stop(); throw error }
            applicationServer = appEngine
            server = engine; running = true
            routeRepairFailed = false
            vpnSyncFailed = false
            status = "Website proxy: 127.0.0.1:\(config.port)\(appEngine == nil ? "" : "; app proxy: 127.0.0.1:\(appsPort)"). System settings unchanged; egress unverified."
        } catch { status = error.localizedDescription }
    }
    func enable() {
        startLocal()
        guard running, let server, !busy else { return }
        let selectedService = service, selectedPort = server.configuration.port
        busy = true; status = "Saving current settings. macOS may request administrator approval."
        DispatchQueue.global().async {
            let result = Result {
                try ProxySettings.applyAndSync(service: selectedService, port: selectedPort)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.recoveryExists = ProxySettings.hasManagedRecovery()
                switch result {
                case .success: self.status = "PAC enabled for \(selectedService). Reopen browser/Mattermost connections. VPN bypass still needs verification."
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
    }
    func disable(completion: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        let hadRecovery = recoveryExists || routeRecoveryExists
        status = hadRecovery ? "Restoring previous proxy settings…" : "Stopping proxy…"
        server?.stop(); applicationServer?.stop(); server = nil; applicationServer = nil; running = false
        DispatchQueue.global().async {
            let result = Result {
                try ProxySettings.restoreManaged()
                try ScopedDirectRoute.restore()
            }
            DispatchQueue.main.async {
                self.busy = false
                self.recoveryExists = ProxySettings.hasManagedRecovery()
                self.routeRecoveryExists = FileManager.default.fileExists(atPath: ScopedDirectRoute.recoveryURL.path)
                switch result {
                case .success:
                    self.status = hadRecovery ? "Previous proxy settings restored and verified." : "Proxy stopped. System settings unchanged."
                    completion?()
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
    }
    func synchronizeVPNProxy() {
        guard !busy, let server else { return }
        busy = true; vpnSyncFailed = false
        status = "Updating V2Box network PAC while preserving original service settings…"
        let port = server.configuration.port
        DispatchQueue.global().async {
            let result = Result { try ProxySettings.synchronizeVPNProxy(port: port) }
            DispatchQueue.main.async {
                self.busy = false; self.recoveryExists = ProxySettings.hasManagedRecovery()
                switch result {
                case .success: self.status = "V2Box network PAC verified. Wi-Fi settings preserved; Mattermost can use domain rules."
                case .failure(let error): self.vpnSyncFailed = true; self.status = error.localizedDescription
                }
            }
        }
    }
    func repairRoute() {
        guard !busy else { return }
        busy = true; routeRepairFailed = false
        status = "Checking physical IPv4 route. macOS may request administrator approval to repair VPN bypass."
        let name = interface
        DispatchQueue.global().async {
            let result = Result { try ScopedDirectRoute.repair(interface: name) }
            DispatchQueue.main.async {
                self.busy = false
                self.routeRecoveryExists = FileManager.default.fileExists(atPath: ScopedDirectRoute.recoveryURL.path)
                switch result {
                case .success(let added): self.status = added ? "Physical scoped route repaired. Existing VPN default route unchanged. Apps can retry connections." : "Physical scoped route already exists. No routing changes needed."
                case .failure(let error): self.routeRepairFailed = true; self.status = error.localizedDescription
                }
            }
        }
    }
    func addApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add applications"
        guard panel.runModal() == .OK else { return }
        var settings = (try? ApplicationSettings.load()) ?? ApplicationSettings(port: UInt16(appPort) ?? 17840, applications: applications)
        settings.port = UInt16(appPort) ?? 17840
        var addedNames: [String] = []
        var skippedMessages: [String] = []
        for url in panel.urls {
            do {
                let app = try SelectedApplication.inspect(url.path)
                try settings.add(app)
                addedNames.append(app.name)
            } catch {
                skippedMessages.append(error.localizedDescription)
            }
        }
        if !addedNames.isEmpty {
            do {
                try Storage.save(settings, to: ApplicationSettings.url)
                applications = settings.applications
                if skippedMessages.isEmpty {
                    status = "Added \(addedNames.joined(separator: ", ")). Quit app normally, then choose Launch Direct."
                } else {
                    status = "Added \(addedNames.joined(separator: ", ")). Note: \(skippedMessages.first ?? "")"
                }
            } catch { status = error.localizedDescription }
        } else if let firstErr = skippedMessages.first {
            status = firstErr
        }
    }
    func removeApplication(_ app: SelectedApplication) {
        do {
            let remaining = applications.filter { $0.id != app.id }
            try Storage.save(ApplicationSettings(port: UInt16(appPort) ?? 17840, applications: remaining), to: ApplicationSettings.url)
            applications = remaining
        } catch { status = error.localizedDescription }
    }
    func launchApplication(_ app: SelectedApplication) {
        startLocal()
        guard let applicationServer else { return }
        do {
            try app.launchDirect(port: applicationServer.boundPort)
            status = "Launched \(app.name) with direct physical interface proxy (\(app.adapterKindName ?? "proxy adapter"))."
        } catch { status = error.localizedDescription }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 31, weight: .semibold)).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PointsWoman").font(.system(size: 26, weight: .bold))
                    Text("Selected domains. Your direct connection.").foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.running ? Color.green : Color.gray).frame(width: 10, height: 10)
            }
            Divider()
            HStack {
                Picker("Direct interface", selection: $model.interface) {
                    ForEach(model.interfaces, id: \.self) { Text($0).tag($0) }
                }
                Button { model.refreshInterfaces() } label: { Image(systemName: "arrow.clockwise") }
                Text("Proxy port")
                TextField("17839", text: $model.port).frame(width: 72)
            }.disabled(model.running || model.busy)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Applications").font(.headline)
                        Spacer()
                        Text("App proxy port")
                        TextField("17840", text: $model.appPort).frame(width: 70).disabled(model.running || model.busy)
                        Button("Add apps…") { model.addApplications() }.disabled(model.running || model.busy)
                    }
                    if model.applications.isEmpty { Text("Add ABDownloadManager, BlueStacks, Chrome, Mattermost, or any app.").foregroundStyle(.secondary) }
                    ForEach(model.applications) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 25, height: 25)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                HStack(spacing: 4) {
                                    if let adapter = app.adapterKindName {
                                        Text(adapter).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.15)).cornerRadius(3)
                                    }
                                    Text("Direct physical interface bypass • Port \(model.appPort)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Launch Direct") { model.launchApplication(app) }.disabled(model.busy)
                            Button { model.removeApplication(app) } label: { Image(systemName: "minus.circle") }.disabled(model.running || model.busy)
                        }
                    }
                    Text("All apps supported (Chromium, Electron, Java/JVM, Universal). In-app manual proxy: HTTP 127.0.0.1:\(model.appPort). For ABDownloadManager, config is auto-applied.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(5)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Bypass domains").font(.headline)
                TextEditor(text: $model.domains).font(.system(.body, design: .monospaced))
                    .padding(5).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))
                Toggle("Include subdomains of every listed domain", isOn: $model.subdomains)
                Text("One hostname per line. Add login and file hosts separately when needed.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.running || model.busy)
            Picker("Apply to network service", selection: $model.service) {
                ForEach(model.services, id: \.self) { Text($0).tag($0) }
            }.disabled(model.busy || model.recoveryExists)
            HStack {
                Button("Start proxy only") { model.startLocal() }.disabled(model.running || model.busy)
                Button("Repair direct route") { model.repairRoute() }.disabled(model.busy)
                Button("Enable for network") { model.enable() }.disabled(model.busy || model.recoveryExists)
                Button(model.recoveryExists ? "Restore settings & stop" : "Stop") { model.disable() }
                    .disabled(model.busy || (!model.running && !model.recoveryExists && !model.routeRecoveryExists))
            }
            HStack {
                Button("Refresh VPN rules") { model.synchronizeVPNProxy() }.disabled(!model.running || model.busy)
                Button("Copy PAC URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("http://127.0.0.1:\(model.port)/proxy.pac", forType: .string)
                }.disabled(!model.running)
                Button("Copy App Proxy (Port \(model.appPort))") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("127.0.0.1:\(model.appPort)", forType: .string)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if model.running {
                    Text(model.stats).font(.caption.monospacedDigit())
                    Text(model.lastEvent).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            Text("DNS follows system settings. No TLS decryption. Calls/UDP and arbitrary app routing are outside v1. VPN enforcement may block direct connections. PAC support and real egress must be tested per client.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24)
        }.frame(width: 700, height: 820)
    }
}

func makePWMonogramMenuBarImage(active: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setAllowsAntialiasing(true)
        ctx?.setShouldAntialias(true)

        let pStroke: NSColor
        let wStroke: NSColor
        let nodeColor: NSColor
        let arrowColor: NSColor

        if !active {
            let c = NSColor.black
            pStroke = c
            wStroke = c
            nodeColor = c
            arrowColor = c
        } else {
            // Midnight Obsidian / Cyber Cyan & Neon Magenta active state
            pStroke = NSColor(calibratedRed: 0.08, green: 0.78, blue: 0.92, alpha: 1.0)
            wStroke = NSColor(calibratedRed: 0.96, green: 0.28, blue: 0.68, alpha: 1.0)
            nodeColor = pStroke
            arrowColor = wStroke
        }

        // P Stem & Loop
        let pPath = NSBezierPath()
        pPath.move(to: NSPoint(x: 3.2, y: 5.2))
        pPath.line(to: NSPoint(x: 3.2, y: 13.2))
        pPath.curve(to: NSPoint(x: 3.2, y: 9.2),
                    controlPoint1: NSPoint(x: 8.0, y: 13.2),
                    controlPoint2: NSPoint(x: 8.0, y: 9.2))
        pPath.line(to: NSPoint(x: 3.2, y: 9.2))
        pPath.lineWidth = 1.6
        pPath.lineCapStyle = .round
        pPath.lineJoinStyle = .round
        pStroke.setStroke()
        pPath.stroke()

        // Origin Node circle
        let node = NSBezierPath(ovalIn: NSRect(x: 1.9, y: 3.9, width: 2.6, height: 2.6))
        nodeColor.setFill()
        node.fill()

        // W Path
        let wPath = NSBezierPath()
        wPath.move(to: NSPoint(x: 5.6, y: 9.2))
        wPath.curve(to: NSPoint(x: 7.8, y: 4.8),
                    controlPoint1: NSPoint(x: 6.2, y: 9.2),
                    controlPoint2: NSPoint(x: 7.0, y: 4.8))
        wPath.curve(to: NSPoint(x: 10.0, y: 9.2),
                    controlPoint1: NSPoint(x: 8.6, y: 4.8),
                    controlPoint2: NSPoint(x: 9.2, y: 9.2))
        wPath.curve(to: NSPoint(x: 12.2, y: 4.8),
                    controlPoint1: NSPoint(x: 10.8, y: 9.2),
                    controlPoint2: NSPoint(x: 11.4, y: 4.8))
        wPath.curve(to: NSPoint(x: 14.8, y: 12.5),
                    controlPoint1: NSPoint(x: 13.0, y: 4.8),
                    controlPoint2: NSPoint(x: 13.8, y: 10.5))
        wPath.lineWidth = 1.6
        wPath.lineCapStyle = .round
        wPath.lineJoinStyle = .round
        wStroke.setStroke()
        wPath.stroke()

        // Arrowhead
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 12.4, y: 12.5))
        arrow.line(to: NSPoint(x: 15.0, y: 12.5))
        arrow.line(to: NSPoint(x: 15.0, y: 9.9))
        arrow.lineWidth = 1.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrowColor.setStroke()
        arrow.stroke()

        return true
    }
    img.isTemplate = !active
    return img
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var finishing = false
    var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appEntry = NSMenuItem()
        let appMenu = NSMenu(title: "PointsWoman")
        appMenu.addItem(NSMenuItem(title: "About PointsWoman", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit PointsWoman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appEntry.submenu = appMenu; mainMenu.addItem(appEntry)
        let editEntry = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editEntry.submenu = editMenu; mainMenu.addItem(editEntry)
        NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 820), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PointsWoman"
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.isReleasedWhenClosed = false
        window.center(); showWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = makePWMonogramMenuBarImage(active: false)
        cancellable = model.$running.receive(on: DispatchQueue.main).sink { [weak self] isRunning in
            self?.statusItem.button?.image = makePWMonogramMenuBarImage(active: isRunning)
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open PointsWoman", action: #selector(showWindow), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let restore = NSMenuItem(title: "Restore settings & stop", action: #selector(restoreSettings), keyEquivalent: "")
        restore.target = self; menu.addItem(restore)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PointsWoman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func restoreSettings() { model.disable() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finishing { return .terminateNow }
        guard !model.busy else { showWindow(); return .terminateCancel }
        if model.running || model.recoveryExists || model.routeRecoveryExists {
            model.disable { DispatchQueue.main.async { self.finishing = true; NSApp.terminate(nil) } }
            return .terminateCancel
        }
        return .terminateNow
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
