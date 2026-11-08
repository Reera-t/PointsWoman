import Foundation
import Darwin

public struct DomainRule: Codable, Equatable, Sendable {
    public var host: String
    public var includeSubdomains: Bool

    public init(_ value: String, includeSubdomains: Bool = false) throws {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.count <= 253, !host.contains(":"),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw PWError.message("Invalid hostname: use an ASCII domain, without scheme, path, port, or wildcard.") }
        self.host = host
        self.includeSubdomains = includeSubdomains
    }

    public func matches(_ value: String) -> Bool {
        let candidate = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return candidate == host || (includeSubdomains && candidate.hasSuffix("." + host))
    }
}

public enum PWError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var interface: String
    public var port: UInt16
    public var rules: [DomainRule]

    public init(interface: String = "en0", port: UInt16 = 17839, rules: [DomainRule]? = nil) {
        self.interface = interface
        self.port = port
        self.rules = rules ?? [try! DomainRule("chat.example.com"), try! DomainRule("app.example.com")]
    }

    public func validate() throws {
        guard port > 1023 else { throw PWError.message("Choose an unprivileged port from 1024 to 65535.") }
        guard !interface.isEmpty, interface.utf8.count < IFNAMSIZ,
              interface.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { throw PWError.message("Invalid interface name.") }
        guard !rules.isEmpty else { throw PWError.message("Add at least one bypass domain.") }
        for rule in rules { _ = try DomainRule(rule.host, includeSubdomains: rule.includeSubdomains) }
    }

    public func allows(_ host: String) -> Bool { rules.contains { $0.matches(host) } }

    public func pac() -> String {
        let conditions = rules.map { rule in
            let name = String(data: try! JSONEncoder().encode(rule.host), encoding: .utf8)!
            return rule.includeSubdomains
                ? "(host === \(name) || dnsDomainIs(host, '.' + \(name)))"
                : "host === \(name)"
        }.joined(separator: " ||\n        ")
        return """
        // PointsWoman: DIRECT means the existing network/VPN path, not physical bypass.
        function FindProxyForURL(url, host) {
            host = host.toLowerCase().replace(/\\.$/, '');
            if (\(conditions)) return "PROXY 127.0.0.1:\(port)";
            return "DIRECT";
        }
        """
    }
}

public enum Storage {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PointsWoman", isDirectory: true)
    }
    public static var configURL: URL { directory.appendingPathComponent("config.json") }
    public static var recoveryURL: URL { directory.appendingPathComponent("proxy-recovery.json") }

    public static func load(from url: URL = configURL) throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct NetworkInterface: Sendable {
    public let name: String
    public let index: UInt32
    public let up: Bool

    public static func list(includeLoopback: Bool = false) -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [String: NetworkInterface] = [:]
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            let flags = item.pointee.ifa_flags
            guard includeLoopback || (name.hasPrefix("en") && flags & UInt32(IFF_LOOPBACK) == 0) else { continue }
            result[name] = NetworkInterface(name: name, index: if_nametoindex(name), up: flags & UInt32(IFF_UP) != 0)
        }
        return result.values.sorted { $0.name < $1.name }
    }
}
