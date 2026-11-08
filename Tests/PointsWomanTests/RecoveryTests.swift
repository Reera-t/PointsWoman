import Foundation
import PointsWomanCore

final class RecoveryTests {
    final class VPNMock {
        var connected = true
        var effective = false
        var urls = ["Wi-Fi": "http://old.example/disabled.pac", "V2BOX": "http://vpn.example/disabled.pac"]
        var enabled = ["Wi-Fi": false, "V2BOX": false]
        var authorizationCount = 0
        func run(_ executable: String, _ arguments: [String]) throws -> String {
            if executable == "/usr/sbin/scutil" {
                if arguments == ["--nc", "list"] { return "* (\(connected ? "Connected" : "Disconnected")) id VPN (hossin.asaadi.V2Box) \"V2BOX\" [VPN]" }
                return effective ? "  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : http://127.0.0.1:17839/proxy.pac" : "  ProxyAutoConfigEnable : 0"
            }
            if arguments[0] == "-listallnetworkservices" { return "Services\nWi-Fi\nV2BOX" }
            if arguments[0] == "-getautoproxyurl" {
                let service = arguments[1]
                return "URL: \(urls[service]!)\nEnabled: \(enabled[service]! ? "Yes" : "No")"
            }
            if arguments[0] == "-getproxyautodiscovery" { return "Auto Proxy Discovery: Off" }
            return "Enabled: No"
        }
        func authorize(_ shell: String) throws {
            authorizationCount += 1
            for service in ["V2BOX", "Wi-Fi"] where shell.contains("'\(service)'") {
                let isOn = shell.contains("'-setautoproxystate' '\(service)' 'on'") || (!shell.contains("'-setautoproxystate' '\(service)' 'off'") && shell.contains("'on'"))
                enabled[service] = isOn
                urls[service] = isOn ? "http://127.0.0.1:17839/proxy.pac" : service == "Wi-Fi" ? "http://old.example/disabled.pac" : "http://vpn.example/disabled.pac"
                if service == "V2BOX" { effective = isOn }
            }
        }
    }
    func testV2BoxPrimaryPACAndIndependentRecovery() throws {
        try withSnapshot { primary in
            let mock = VPNMock()
            try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: primary, run: mock.run, authorize: mock.authorize)
            let wifiOriginal = try Data(contentsOf: primary)
            XCTAssertTrue(try ProxySettings.needsVPNProxySync(port: 17839, primary: primary, run: mock.run))
            XCTAssertTrue(try ProxySettings.synchronizeVPNProxy(port: 17839, primary: primary, run: mock.run, authorize: mock.authorize))
            XCTAssertEqual(try Data(contentsOf: primary), wifiOriginal)
            XCTAssertTrue(mock.effective)
            XCTAssertEqual(try ProxySettings.snapshot(at: ProxySettings.vpnRecoveryURL(primary: primary)).previousURL, "http://vpn.example/disabled.pac")
            XCTAssertFalse(try ProxySettings.synchronizeVPNProxy(port: 17839, primary: primary, run: mock.run, authorize: mock.authorize))
            try ProxySettings.restoreManaged(primary: primary, run: mock.run, authorize: mock.authorize)
            XCTAssertEqual(mock.enabled, ["Wi-Fi": false, "V2BOX": false])
            XCTAssertFalse(ProxySettings.hasManagedRecovery(primary: primary, run: mock.run))
        }
    }
    func testV2BoxReconnectPreservesOriginalSnapshot() throws {
        try withSnapshot { primary in
            let mock = VPNMock()
            try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: primary, run: mock.run, authorize: mock.authorize)
            try ProxySettings.synchronizeVPNProxy(port: 17839, primary: primary, run: mock.run, authorize: mock.authorize)
            let saved = try Data(contentsOf: ProxySettings.vpnRecoveryURL(primary: primary))
            mock.enabled["V2BOX"] = false; mock.urls["V2BOX"] = "http://vpn.example/disabled.pac"; mock.effective = false
            XCTAssertTrue(try ProxySettings.synchronizeVPNProxy(port: 17839, primary: primary, run: mock.run, authorize: mock.authorize))
            XCTAssertEqual(try Data(contentsOf: ProxySettings.vpnRecoveryURL(primary: primary)), saved)
            XCTAssertTrue(mock.effective)
        }
    }
    func testV2BoxForeignPACAndDisconnectedVPNPreserved() throws {
        try withSnapshot { primary in
            let mock = VPNMock()
            try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: primary, run: mock.run, authorize: mock.authorize)
            mock.connected = false
            XCTAssertFalse(try ProxySettings.synchronizeVPNProxy(port: 17839, primary: primary, run: mock.run, authorize: mock.authorize))
            mock.connected = true; mock.enabled["V2BOX"] = true; mock.urls["V2BOX"] = "http://company.example/proxy.pac"
            XCTAssertThrowsError(try ProxySettings.synchronizeVPNProxy(port: 17839, primary: primary, run: mock.run, authorize: mock.authorize))
            XCTAssertEqual(mock.authorizationCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProxySettings.vpnRecoveryURL(primary: primary).path))
        }
    }
    func testScopedRouteRepairAndOwnershipRecovery() throws {
        try withSnapshot { url in
            var gateway: String?
            var commands: [String] = []
            let run: (String, [String]) throws -> String = { path, _ in
                if path == "/usr/sbin/ipconfig" { return "192.168.1.1" }
                guard let gateway else { throw PWError.message("not in table") }
                return "  interface: en0\n    gateway: \(gateway)\n      flags: <UP,GATEWAY,IFSCOPE>"
            }
            let authorize: (String) throws -> Void = { shell in
                commands.append(shell)
                gateway = shell.contains("'add'") ? "192.168.1.1" : nil
            }
            XCTAssertTrue(try ScopedDirectRoute.repair(interface: "en0", recovery: url, run: run, authorize: authorize))
            XCTAssertFalse(try ScopedDirectRoute.repair(interface: "en0", recovery: url, run: run, authorize: authorize))
            XCTAssertEqual(commands.count, 1)
            XCTAssertTrue(commands[0].contains("'-ifscope' 'en0' 'default'"))
            try ScopedDirectRoute.restore(recovery: url, run: run, authorize: authorize)
            XCTAssertNil(gateway)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testExistingScopedRouteNotOwnedOrRemoved() throws {
        try withSnapshot { url in
            let run: (String, [String]) throws -> String = { _, _ in "interface: en0\ngateway: 192.168.1.1\nflags: <UP,IFSCOPE>" }
            XCTAssertFalse(try ScopedDirectRoute.repair(interface: "en0", recovery: url, run: run, authorize: { _ in XCTFailUnexpectedRouteMutation() }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testChangedOwnedRoutePreserved() throws {
        try withSnapshot { url in
            try Storage.save(ScopedDirectRoute.Snapshot(interface: "en0", gateway: "192.168.1.1"), to: url)
            let run: (String, [String]) throws -> String = { _, _ in "interface: en0\ngateway: 192.168.1.2\nflags: <UP,IFSCOPE>" }
            XCTAssertThrowsError(try ScopedDirectRoute.restore(recovery: url, run: run, authorize: { _ in XCTFailUnexpectedRouteMutation() }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
    final class NetworkMock {
        var url = "http://old.example/disabled.pac"
        var previousURL = "http://old.example/disabled.pac"
        var enabled = false
        var conflicting = false
        var cancel = false
        var authorized: [String] = []
        func run(_ executable: String, _ arguments: [String]) throws -> String {
            XCTAssertEqual(executable, "/usr/sbin/networksetup")
            switch arguments.first {
            case "-listallnetworkservices": return "An asterisk denotes disabled service\nWi-Fi\n*Disabled"
            case "-getautoproxyurl": return "URL: \(url)\nEnabled: \(enabled ? "Yes" : "No")"
            case "-getproxyautodiscovery": return "Auto Proxy Discovery: Off"
            default: return "Enabled: \(conflicting ? "Yes" : "No")\nServer: test\nPort: 0"
            }
        }
        func authorize(_ shell: String) throws {
            authorized.append(shell)
            if cancel { throw PWError.message("User canceled.") }
            if shell.contains("'on'") { url = "http://127.0.0.1:17839/proxy.pac"; enabled = true }
            else { url = previousURL; enabled = false }
        }
    }
    func testApplyAndRestorePreserveDisabledPACURL() throws {
        try withSnapshot { url in
            let mock = NetworkMock()
            try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: url, run: mock.run, authorize: mock.authorize)
            XCTAssertTrue(mock.enabled)
            XCTAssertEqual(try ProxySettings.snapshot(at: url).previousURL, "http://old.example/disabled.pac")
            try ProxySettings.restore(recovery: url, run: mock.run, authorize: mock.authorize)
            XCTAssertFalse(mock.enabled)
            XCTAssertEqual(mock.url, "http://old.example/disabled.pac")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(mock.authorized.count, 2)
        }
    }
    func testConflictMakesNoChanges() throws {
        try withSnapshot { url in
            let mock = NetworkMock(); mock.conflicting = true
            XCTAssertThrowsError(try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: url, run: mock.run, authorize: mock.authorize))
            XCTAssertTrue(mock.authorized.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testCancelRetainsSnapshotAndRecoverableOriginalState() throws {
        try withSnapshot { url in
            let mock = NetworkMock(); mock.cancel = true
            XCTAssertThrowsError(try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: url, run: mock.run, authorize: mock.authorize))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            mock.cancel = false
            try ProxySettings.restore(recovery: url, run: mock.run, authorize: mock.authorize)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testExternalChangeIsNotOverwritten() throws {
        try withSnapshot { url in
            let mock = NetworkMock()
            try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: url, run: mock.run, authorize: mock.authorize)
            mock.url = "http://company.example/new.pac"
            XCTAssertThrowsError(try ProxySettings.restore(recovery: url, run: mock.run, authorize: mock.authorize))
            XCTAssertEqual(mock.authorized.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testUnverifiedApplyRetainsSnapshot() throws {
        try withSnapshot { url in
            let mock = NetworkMock()
            XCTAssertThrowsError(try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: url, run: mock.run, authorize: { _ in }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testExistingSnapshotPreventsOverwrite() throws {
        try withSnapshot { url in
            let mock = NetworkMock()
            try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: url, run: mock.run, authorize: mock.authorize)
            let original = try Data(contentsOf: url)
            XCTAssertThrowsError(try ProxySettings.apply(service: "Wi-Fi", port: 17840, recovery: url, run: mock.run, authorize: mock.authorize))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
    func testUnsetPACRestoredWithoutInvalidEmptyURLCommand() throws {
        try withSnapshot { url in
            let mock = NetworkMock(); mock.url = "(null)"; mock.previousURL = "(null)"
            try ProxySettings.apply(service: "Wi-Fi", port: 17839, recovery: url, run: mock.run, authorize: mock.authorize)
            try ProxySettings.restore(recovery: url, run: mock.run, authorize: mock.authorize, clearUnsetCommand: { service, expected in
                XCTAssertEqual(service, "Wi-Fi")
                XCTAssertEqual(expected, "http://127.0.0.1:17839/proxy.pac")
                return "mock-clear-unset"
            })
            XCTAssertTrue(mock.authorized.last?.contains("mock-clear-unset") == true)
            XCTAssertFalse(mock.authorized.last?.contains("'-setautoproxyurl' 'Wi-Fi' ''") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    private func withSnapshot(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("snapshot.json"))
    }
}
