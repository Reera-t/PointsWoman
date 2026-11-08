// Minimal assertion runner keeps full Xcode/XCTest optional for this project.
import Foundation
import Darwin

var failures = 0
func fail(_ message: String, file: StaticString, line: UInt) {
    failures += 1; print("FAIL \(file):\(line): \(message)")
}
func XCTFailUnexpectedRouteMutation() { fail("Unexpected privileged route mutation", file: #filePath, line: #line) }
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { fail("Expected true. \(message)", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { fail("Expected false. \(message)", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x != y { fail("\(x) != \(y). \(message)", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { fail("Expected nil.", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); fail("Expected error. \(message)", file: file, line: line) } catch {}
}

let core = CoreTests(), recovery = RecoveryTests()
let applications = ApplicationTests()
let checks: [(String, () throws -> Void)] = [
    ("Exact domains and case", core.testExactDomainAndCase),
    ("Subdomain boundaries", core.testSubdomainsRespectLabelBoundary),
    ("Invalid domains", core.testInvalidDomains),
    ("PAC fallback policy", core.testPACHasNoDirectFallbackForSelectedDomains),
    ("Configuration validation", core.testConfigurationValidation),
    ("Configuration round trip and permissions", core.testConfigRoundTrip),
    ("Corrupt configuration preserved", core.testCorruptConfigIsNotSilentlyOverwritten),
    ("CONNECT parsing", core.testCONNECT),
    ("IPv6 authority parsing", core.testIPv6CONNECT),
    ("HTTP rewriting and proxy credentials", core.testHTTPRewritingPreservesEncodedPathAndStripsProxyCredentials),
    ("WebSocket headers", core.testWebSocketUpgrade),
    ("Malformed and ambiguous requests", core.testAmbiguousAndMalformedRequestsRejected),
    ("Settings parsing and shell quoting", core.testProxySettingsParsingAndShellEscaping),
    ("Proxy server start stop restart on same port", core.testProxyServerStartStopRestart),
    ("Apply/restore round trip", recovery.testApplyAndRestorePreserveDisabledPACURL),
    ("Proxy conflicts", recovery.testConflictMakesNoChanges),
    ("Administrator cancellation recovery", recovery.testCancelRetainsSnapshotAndRecoverableOriginalState),
    ("External settings preserved", recovery.testExternalChangeIsNotOverwritten),
    ("Unverified apply recovery", recovery.testUnverifiedApplyRetainsSnapshot),
    ("Existing recovery snapshot protected", recovery.testExistingSnapshotPreventsOverwrite),
    ("Chromium proxy adapter", applications.testChromiumAdapterAndArguments),
    ("Electron proxy adapter", applications.testElectronDetection),
    ("Unsupported apps refused", applications.testUnsupportedAppsRejectedWithoutSaving),
    ("App selection persistence and deduplication", applications.testApplicationSettingsRoundTripAndDeduplication),
    ("Invalid app bundles", applications.testInvalidApplicationRejected),
    ("VPN clients excluded from app routing", applications.testVPNClientIsNotOfferedAsRoutableElectronApp),
    ("Unset PAC URL recovery", recovery.testUnsetPACRestoredWithoutInvalidEmptyURLCommand),
    ("Scoped route repair and owned cleanup", recovery.testScopedRouteRepairAndOwnershipRecovery),
    ("Preexisting scoped route preserved", recovery.testExistingScopedRouteNotOwnedOrRemoved),
    ("Externally changed scoped route preserved", recovery.testChangedOwnedRoutePreserved),
    ("V2Box primary PAC and independent recovery", recovery.testV2BoxPrimaryPACAndIndependentRecovery),
    ("V2Box reconnect snapshot preserved", recovery.testV2BoxReconnectPreservesOriginalSnapshot),
    ("Foreign PAC and disconnected VPN preserved", recovery.testV2BoxForeignPACAndDisconnectedVPNPreserved)
]
for (name, check) in checks {
    let before = failures
    do { try check() } catch { fail("\(name): \(error.localizedDescription)", file: #filePath, line: #line) }
    print("\(before == failures ? "PASS" : "FAIL") \(name)")
}
print("\(checks.count) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
