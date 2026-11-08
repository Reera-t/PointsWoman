import Foundation
import AppKit

public struct SelectedApplication: Codable, Equatable, Identifiable {
    public let path: String
    public let bundleIdentifier: String
    public let name: String
    public let supportsProxyLaunch: Bool
    public var id: String { path }

    public static func inspect(_ path: String) throws -> SelectedApplication {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PWError.message("Choose a valid macOS application bundle (.app).")
        }
        let chromium: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
                                    "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac"]
        let electron = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        let identity = (identifier + " " + name).lowercased()
        let networkClient = ["vpn", "forticlient", "fortinet", "v2box", "hiddify", "clash", "windscribe", "streisand", "pointswoman"]
            .contains(where: { identity.contains($0) }) || name.lowercased() == "happ"
        return SelectedApplication(path: url.path, bundleIdentifier: identifier, name: name,
                                   supportsProxyLaunch: !networkClient && (chromium.contains(identifier) || electron))
    }

    public func launchArguments(port: UInt16) throws -> [String] {
        guard supportsProxyLaunch else { throw PWError.message("\(name) has no supported proxy launch adapter. Use website rules for Orion/Safari; arbitrary app capture needs a signed Network Extension.") }
        return ["--proxy-server=http://127.0.0.1:\(port)"]
    }

    public func launchDirect(port: UInt16) throws {
        let current = try SelectedApplication.inspect(path)
        guard current.bundleIdentifier == bundleIdentifier else { throw PWError.message("Application identity changed. Remove and add it again.") }
        let arguments = try current.launchArguments(port: port)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleIdentifier).isEmpty else {
            throw PWError.message("Quit \(current.name) normally first, then launch it from PointsWoman. Running apps cannot receive new proxy launch options.")
        }
        _ = try Command.run("/usr/bin/open", ["-a", current.path, "--args"] + arguments)
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
