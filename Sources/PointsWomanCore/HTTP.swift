import Foundation

public struct ProxyRequest {
    public let method: String
    public let host: String
    public let port: UInt16
    public let tunnel: Bool
    public let forwardedHeader: Data

    public static func parse(_ data: Data) throws -> ProxyRequest {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\r\n\r\n") else {
            throw PWError.message("Malformed HTTP header.")
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])),
              !parts[0].isEmpty, parts[0].utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw PWError.message("Malformed request line.")
        }
        let method = String(parts[0]), target = String(parts[1])
        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw PWError.message("Malformed header field.") }
            let key = String(line[..<colon])
            guard key.utf8.allSatisfy({ (33...126).contains($0) && $0 != 58 }) else { throw PWError.message("Invalid header name.") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else { throw PWError.message("Invalid header value.") }
            headers.append((key, value))
        }
        guard headers.filter({ $0.0.lowercased() == "host" }).count <= 1 else { throw PWError.message("Duplicate Host header.") }
        let contentLengths = headers.filter { $0.0.lowercased() == "content-length" }
        let encodings = headers.filter { $0.0.lowercased() == "transfer-encoding" }
        guard contentLengths.count <= 1, encodings.count <= 1, contentLengths.isEmpty || encodings.isEmpty else {
            throw PWError.message("Ambiguous HTTP framing.")
        }
        if let length = contentLengths.first?.1 {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(length) != nil else {
                throw PWError.message("Invalid Content-Length.")
            }
        }
        if let encoding = encodings.first?.1, encoding.lowercased() != "chunked" { throw PWError.message("Unsupported Transfer-Encoding.") }

        if method == "CONNECT" {
            let (host, port) = try authority(target, defaultPort: nil)
            return ProxyRequest(method: method, host: host, port: port, tunnel: true, forwardedHeader: Data())
        }
        guard let url = URLComponents(string: target), url.scheme?.lowercased() == "http",
              let rawHost = url.host, !rawHost.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
              (url.port ?? 80) > 0, (url.port ?? 80) <= 65535 else {
            throw PWError.message("Use an absolute HTTP URL, or CONNECT for HTTPS.")
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let port = UInt16(url.port ?? 80)
        if let declared = headers.first(where: { $0.0.lowercased() == "host" })?.1 {
            let (declaredHost, declaredPort) = try authority(declared, defaultPort: 80)
            guard declaredHost == host, declaredPort == port else { throw PWError.message("Host does not match request target.") }
        }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        let upgrade = headers.contains { $0.0.lowercased() == "upgrade" && $0.1.lowercased() == "websocket" }
        let removed: Set<String> = ["host", "proxy-authorization", "proxy-connection", "connection", "keep-alive"]
        let kept = headers.filter { !removed.contains($0.0.lowercased()) }.map { "\($0.0): \($0.1)" }
        let hostHeader = host.contains(":") ? "[\(host)]" : host
        let output = ["\(method) \(path) HTTP/1.1", "Host: \(hostHeader)\(port == 80 ? "" : ":\(port)")"] + kept + ["Connection: \(upgrade ? "Upgrade" : "close")", "", ""]
        return ProxyRequest(method: method, host: host, port: port, tunnel: false,
                            forwardedHeader: Data(output.joined(separator: "\r\n").utf8))
    }

    private static func authority(_ value: String, defaultPort: UInt16?) throws -> (String, UInt16) {
        guard !value.contains(where: { $0.isWhitespace }), !value.contains("/"), !value.contains("@"),
              let url = URLComponents(string: "http://" + value), let rawHost = url.host,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              let number = url.port ?? defaultPort.map(Int.init), number > 0, number <= 65535 else {
            throw PWError.message("Invalid host or port.")
        }
        return (rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(), UInt16(number))
    }
}
