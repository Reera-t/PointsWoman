import Foundation
import PointsWomanCore

final class CoreTests {
    func testExactDomainAndCase() throws {
        let rule = try DomainRule(" Chat.Example.Com ")
        XCTAssertTrue(rule.matches("CHAT.EXAMPLE.COM."))
        XCTAssertFalse(rule.matches("evilchat.example.com"))
        XCTAssertFalse(rule.matches("files.chat.example.com"))
        XCTAssertFalse(rule.matches("chat.example.com.attacker.example"))
    }
    func testSubdomainsRespectLabelBoundary() throws {
        let rule = try DomainRule("example.com", includeSubdomains: true)
        XCTAssertTrue(rule.matches("example.com"))
        XCTAssertTrue(rule.matches("chat.example.com"))
        XCTAssertFalse(rule.matches("evilexample.com"))
        XCTAssertFalse(rule.matches("example.com.attacker.example"))
    }
    func testInvalidDomains() {
        for input in ["", "https://example.com", "example.com/path", "*.example.com", "example.com:443", "a..com", "-a.com", "a-.com", "a\".com", "example.com\nattack", "é.com"] {
            XCTAssertThrowsError(try DomainRule(input), input)
        }
    }
    func testPACHasNoDirectFallbackForSelectedDomains() {
        let config = Configuration()
        let script = config.pac()
        XCTAssertTrue(script.contains("return \"PROXY 127.0.0.1:17839\""))
        XCTAssertFalse(script.contains("17839; DIRECT"))
        XCTAssertTrue(script.contains("return \"DIRECT\""))
        XCTAssertFalse(script.contains("dnsResolve"))
    }
    func testConfigurationValidation() throws {
        XCTAssertThrowsError(try Configuration(interface: "en0; echo bad").validate())
        XCTAssertThrowsError(try Configuration(port: 80).validate())
        XCTAssertThrowsError(try Configuration(rules: []).validate())
        try Configuration().validate()
    }
    func testConfigRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let config = Configuration(interface: "en1", port: 18181, rules: [try DomainRule("example.com", includeSubdomains: true)])
        try Storage.save(config, to: url)
        XCTAssertEqual(try Storage.load(from: url), config)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testCorruptConfigIsNotSilentlyOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try Storage.load(from: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }
    func testCONNECT() throws {
        let request = try parse("CONNECT chat.example.com:443 HTTP/1.1\r\nHost: chat.example.com:443\r\n\r\n")
        XCTAssertEqual(request.host, "chat.example.com")
        XCTAssertEqual(request.port, 443)
        XCTAssertTrue(request.tunnel)
    }
    func testIPv6CONNECT() throws {
        let request = try parse("CONNECT [::1]:8443 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(request.host, "::1")
        XCTAssertEqual(request.port, 8443)
    }
    func testHTTPRewritingPreservesEncodedPathAndStripsProxyCredentials() throws {
        let request = try parse("POST http://example.com:8080/a%20b?x=%2F HTTP/1.1\r\nHost: example.com:8080\r\nProxy-Authorization: secret\r\nProxy-Connection: keep-alive\r\nContent-Length: 3\r\n\r\n")
        let forwarded = String(decoding: request.forwardedHeader, as: UTF8.self)
        XCTAssertTrue(forwarded.hasPrefix("POST /a%20b?x=%2F HTTP/1.1\r\n"))
        XCTAssertTrue(forwarded.contains("Host: example.com:8080\r\n"))
        XCTAssertTrue(forwarded.contains("Connection: close\r\n"))
        XCTAssertFalse(forwarded.contains("secret"))
        XCTAssertFalse(forwarded.lowercased().contains("proxy-"))
    }
    func testWebSocketUpgrade() throws {
        let request = try parse("GET http://example.com/socket HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
        XCTAssertTrue(String(decoding: request.forwardedHeader, as: UTF8.self).contains("Connection: Upgrade\r\n"))
    }
    func testAmbiguousAndMalformedRequestsRejected() {
        let requests = [
            "CONNECT example.com HTTP/1.1\r\n\r\n",
            "CONNECT example.com:0 HTTP/1.1\r\n\r\n",
            "CONNECT example.com:99999 HTTP/1.1\r\n\r\n",
            "CONNECT user:secret@example.com:443 HTTP/1.1\r\n\r\n",
            "GET /relative HTTP/1.1\r\nHost: example.com\r\n\r\n",
            "GET https://example.com/ HTTP/1.1\r\n\r\n",
            "GET http://example.com/ HTTP/1.1\r\nHost: attacker.example\r\n\r\n",
            "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nHost: example.com\r\n\r\n",
            "POST http://example.com/ HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST http://example.com/ HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST http://example.com/ HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            "GET http://example.com/ HTTP/1.1\r\n folded: bad\r\n\r\n"
        ]
        for input in requests { XCTAssertThrowsError(try parse(input), input) }
    }
    func testProxySettingsParsingAndShellEscaping() {
        let output = "URL: http://127.0.0.1:17839/proxy.pac\nEnabled: Yes"
        XCTAssertEqual(ProxySettings.value("Enabled", in: output), "Yes")
        XCTAssertNil(ProxySettings.value("Missing", in: output))
        XCTAssertEqual(Command.shellQuote("Wi-Fi ' office; $(x)"), "'Wi-Fi '\\'' office; $(x)'")
    }
    func testProxyServerStartStopRestart() throws {
        let config = Configuration(interface: "en0", port: 19842)
        let server1 = ProxyServer(configuration: config)
        try server1.start()
        XCTAssertEqual(server1.boundPort, 19842)
        server1.stop()
        let server2 = ProxyServer(configuration: config)
        try server2.start()
        XCTAssertEqual(server2.boundPort, 19842)
        server2.stop()
    }
    private func parse(_ text: String) throws -> ProxyRequest { try ProxyRequest.parse(Data(text.utf8)) }
}
