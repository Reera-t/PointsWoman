import Foundation
import AppKit

public struct SelectedApplication: Codable, Equatable, Identifiable {
    public let path: String
    public let bundleIdentifier: String
    public let name: String
    public let supportsProxyLaunch: Bool
    public let adapterKindName: String?
    public var id: String { path }

    public init(path: String, bundleIdentifier: String, name: String, supportsProxyLaunch: Bool, adapterKindName: String? = nil) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.supportsProxyLaunch = supportsProxyLaunch
        self.adapterKindName = adapterKindName
    }

    enum CodingKeys: String, CodingKey {
        case path, bundleIdentifier, name, supportsProxyLaunch, adapterKindName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        name = try container.decode(String.self, forKey: .name)
        supportsProxyLaunch = try container.decode(Bool.self, forKey: .supportsProxyLaunch)
        adapterKindName = try container.decodeIfPresent(String.self, forKey: .adapterKindName)
    }

    var isJavaApplication: Bool {
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/runtime").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/app").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Java").path)
    }

    public static func inspect(_ path: String) throws -> SelectedApplication {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PWError.message("Choose a valid macOS application bundle (.app).")
        }

        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        let identity = (identifier + " " + name).lowercased()

        let networkClient = ["vpn", "forticlient", "fortinet", "v2box", "hiddify", "clash", "windscribe", "streisand", "pointswoman"]
            .contains(where: { identity.contains($0) }) || name.lowercased() == "happ"

        // 1. Chromium detection (Chrome, Canary, Chromium, Brave, Edge, Arc, Vivaldi, Opera, CEF)
        let chromiumIDs: Set<String> = [
            "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary", "com.google.chrome.dev",
            "org.chromium.chromium",
            "com.brave.browser", "com.brave.browser.beta", "com.brave.browser.nightly",
            "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev", "com.microsoft.edgemac.canary",
            "company.thebrowser.browser", // Arc
            "com.vivaldi.vivaldi",         // Vivaldi
            "com.operasoftware.opera",     // Opera
            "com.operasoftware.operagx",   // Opera GX
            "com.yandex.browser"
        ]
        let hasCEF = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework").path)
        let isChromium = chromiumIDs.contains(identifier.lowercased()) || hasCEF || identifier.lowercased().contains("chromium")

        // 2. Electron detection
        let hasElectronFramework = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        let isElectron = hasElectronFramework || identifier.lowercased().hasPrefix("com.electron.")

        // 3. Java / JVM / jpackage detection (ABDownloadManager, Burp Suite, DBeaver, IntelliJ, etc.)
        let hasRuntime = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/runtime").path)
        let hasAppFolder = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/app").path)
        let hasJavaFolder = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Java").path)
        let isJava = hasRuntime || hasAppFolder || hasJavaFolder

        let adapter: String?
        if networkClient {
            adapter = nil
        } else if isChromium {
            adapter = "Chromium"
        } else if isElectron {
            adapter = "Electron"
        } else if isJava {
            adapter = "Java / JVM"
        } else {
            adapter = nil
        }

        let supported = !networkClient && (isChromium || isElectron || isJava)

        return SelectedApplication(
            path: url.path,
            bundleIdentifier: identifier,
            name: name,
            supportsProxyLaunch: supported,
            adapterKindName: adapter
        )
    }

    public func launchArguments(port: UInt16) throws -> [String] {
        guard supportsProxyLaunch else {
            throw PWError.message("\(name) has no supported proxy launch adapter. Use website rules for Orion/Safari; arbitrary app capture needs a signed Network Extension.")
        }
        if adapterKindName == "Java / JVM" || isJavaApplication {
            return [
                "-Dhttp.proxyHost=127.0.0.1",
                "-Dhttp.proxyPort=\(port)",
                "-Dhttps.proxyHost=127.0.0.1",
                "-Dhttps.proxyPort=\(port)",
                "--proxy-server=http://127.0.0.1:\(port)"
            ]
        }
        return ["--proxy-server=http://127.0.0.1:\(port)"]
    }

    public func launchEnvironment(port: UInt16) -> [String: String] {
        var env: [String: String] = [
            "http_proxy": "http://127.0.0.1:\(port)",
            "https_proxy": "http://127.0.0.1:\(port)",
            "all_proxy": "http://127.0.0.1:\(port)",
            "HTTP_PROXY": "http://127.0.0.1:\(port)",
            "HTTPS_PROXY": "http://127.0.0.1:\(port)",
            "ALL_PROXY": "http://127.0.0.1:\(port)"
        ]
        if adapterKindName == "Java / JVM" || isJavaApplication {
            let jvmFlags = "-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=\(port) -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=\(port)"
            env["JAVA_TOOL_OPTIONS"] = jvmFlags
            env["_JAVA_OPTIONS"] = jvmFlags
        }
        return env
    }

    public func launchDirect(port: UInt16) throws {
        let current = try SelectedApplication.inspect(path)
        guard current.bundleIdentifier == bundleIdentifier else {
            throw PWError.message("Application identity changed. Remove and add it again.")
        }
        let arguments = try current.launchArguments(port: port)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleIdentifier).isEmpty else {
            throw PWError.message("Quit \(current.name) normally first, then launch it from PointsWoman. Running apps cannot receive new proxy launch options.")
        }

        var openCommand: [String] = []
        for (k, v) in current.launchEnvironment(port: port) {
            openCommand.append(contentsOf: ["--env", "\(k)=\(v)"])
        }
        openCommand.append(contentsOf: ["-a", current.path, "--args"])
        openCommand.append(contentsOf: arguments)

        _ = try Command.run("/usr/bin/open", openCommand)
    }
}

public struct ApplicationSettings: Codable, Equatable {
    public var port: UInt16
    public var applications: [SelectedApplication]
    public init(port: UInt16 = 17840, applications: [SelectedApplication] = []) {
        self.port = port; self.applications = applications
    }
    public static var url: URL { Storage.directory.appendingPathComponent("applications.json") }
    public static func load(from url: URL = url) throws -> ApplicationSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let mattermost = try? SelectedApplication.inspect("/Applications/Mattermost.app")
            return ApplicationSettings(applications: mattermost.map { [$0] } ?? [])
        }
        let value = try JSONDecoder().decode(ApplicationSettings.self, from: Data(contentsOf: url))
        guard value.port > 1023 else { throw PWError.message("Invalid application proxy port.") }
        return value
    }
    public mutating func add(_ application: SelectedApplication) throws {
        guard application.supportsProxyLaunch else { _ = try application.launchArguments(port: port); return }
        if !applications.contains(where: { $0.path == application.path }) { applications.append(application) }
    }
    public static func discover() -> [SelectedApplication] {
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return roots.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "app" }.compactMap { try? SelectedApplication.inspect($0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
