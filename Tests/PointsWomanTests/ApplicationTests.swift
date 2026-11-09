import Foundation
import PointsWomanCore

final class ApplicationTests {
    func testChromiumAdapterAndArguments() throws {
        try withApp(identifier: "com.google.Chrome") { app in
            XCTAssertTrue(app.supportsProxyLaunch)
            XCTAssertEqual(try app.launchArguments(port: 17840), ["--proxy-server=http://127.0.0.1:17840"])
        }
    }
    func testElectronDetection() throws {
        try withApp(identifier: "test.electron", electron: true) { app in
            XCTAssertTrue(app.supportsProxyLaunch)
        }
    }
    func testJavaAdapterAndArguments() throws {
        try withApp(identifier: "com.abdownloadmanager.desktop", java: true) { app in
            XCTAssertTrue(app.supportsProxyLaunch)
            XCTAssertEqual(app.adapterKindName, "Java / JVM")
            let args = try app.launchArguments(port: 17840)
            XCTAssertTrue(args.contains("-Dhttp.proxyHost=127.0.0.1"))
            XCTAssertTrue(args.contains("-Dhttp.proxyPort=17840"))
            let env = app.launchEnvironment(port: 17840)
            XCTAssertEqual(env["http_proxy"], "http://127.0.0.1:17840")
            XCTAssertTrue(env["JAVA_TOOL_OPTIONS"]?.contains("-Dhttp.proxyHost=127.0.0.1") ?? false)
        }
    }
    func testUniversalAdapterAndArguments() throws {
        try withApp(identifier: "com.bluestacks.BlueStacks") { app in
            XCTAssertTrue(app.supportsProxyLaunch)
            XCTAssertEqual(app.adapterKindName, "Universal / Env")
            var settings = ApplicationSettings()
            try settings.add(app)
            XCTAssertEqual(settings.applications.count, 1)
            let args = try app.launchArguments(port: 17840)
            XCTAssertEqual(args, ["--proxy-server=http://127.0.0.1:17840"])
            let env = app.launchEnvironment(port: 17840)
            XCTAssertEqual(env["http_proxy"], "http://127.0.0.1:17840")
        }
    }
    func testVPNClientRejectedWithoutSaving() throws {
        try withApp(identifier: "net.openvpn.connect", electron: true) { app in
            XCTAssertFalse(app.supportsProxyLaunch)
            var settings = ApplicationSettings()
            XCTAssertThrowsError(try settings.add(app))
            XCTAssertTrue(settings.applications.isEmpty)
            XCTAssertThrowsError(try app.launchArguments(port: 17840))
        }
    }
    func testApplicationSettingsRoundTripAndDeduplication() throws {
        try withApp(identifier: "com.google.Chrome") { app in
            var settings = ApplicationSettings()
            try settings.add(app); try settings.add(app)
            XCTAssertEqual(settings.applications.count, 1)
            let url = URL(fileURLWithPath: app.path).deletingLastPathComponent().appendingPathComponent("apps.json")
            try Storage.save(settings, to: url)
            XCTAssertEqual(try ApplicationSettings.load(from: url), settings)
        }
    }
    func testInvalidApplicationRejected() {
        XCTAssertThrowsError(try SelectedApplication.inspect("/does/not/exist.app"))
        XCTAssertThrowsError(try SelectedApplication.inspect("/bin/sh"))
    }
    func testVPNClientIsNotOfferedAsRoutableElectronApp() throws {
        try withApp(identifier: "net.openvpn.connect", electron: true) { app in
            XCTAssertFalse(app.supportsProxyLaunch)
            XCTAssertThrowsError(try app.launchArguments(port: 17840))
        }
    }
    private func withApp(identifier: String, electron: Bool = false, java: Bool = false, body: (SelectedApplication) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "Example", "CFBundleExecutable": "Example", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        if electron { try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks/Electron Framework.framework"), withIntermediateDirectories: true) }
        if java { try FileManager.default.createDirectory(at: contents.appendingPathComponent("runtime"), withIntermediateDirectories: true) }
        try body(SelectedApplication.inspect(app.path))
    }
}
