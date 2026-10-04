import XCTest
import Foundation
import Darwin
@testable import Traffic

final class BoundedProcessTests: XCTestCase {
    private func process(_ executable: String, _ arguments: [String]) -> Process {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        return process
    }
    private func assertReaped(_ process: Process, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(process.isRunning, file: file, line: line)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(process.processIdentifier, &status, WNOHANG), -1, file: file, line: line)
        XCTAssertEqual(errno, ECHILD, file: file, line: line)
    }
    func testNormalOutputAndFailedExitAreReaped() {
        let success = process("/bin/echo", ["fixture"])
        XCTAssertEqual(BoundedProcess.output(success), Data("fixture\n".utf8)); assertReaped(success)
        let failure = process("/usr/bin/false", [])
        XCTAssertNil(BoundedProcess.output(failure)); assertReaped(failure)
    }
    func testOversizeOutputIsRejectedAndChildReaped() {
        let oversized = process("/usr/bin/yes", ["fixture"])
        XCTAssertNil(BoundedProcess.output(oversized, limit: 64)); assertReaped(oversized)
    }
    func testChildExitKeepsCompleteOutputAtTheSizeLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Traffic-output-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data(repeating: 65, count: 32768)
        try bytes.write(to: url)
        for _ in 0..<5 {
            let child = process("/bin/cat", [url.path])
            XCTAssertEqual(BoundedProcess.output(child), bytes); assertReaped(child)
        }
    }
    func testTimeoutIsBoundedWithAnOpenOrClosedStdout() {
        for child in [process("/bin/sleep", ["10"]), process("/bin/sh", ["-c", "exec 1>&-; exec /bin/sleep 10"])] {
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertNil(BoundedProcess.output(child, timeout: 0.1)); assertReaped(child)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        }
    }
    func testOtherSignedExecutablesFailTailscaleIdentityRequirement() {
        XCTAssertFalse(NetworkInventory.trustedTailscale(executable: URL(fileURLWithPath: "/bin/echo")))
    }
    func testInstalledTailscaleSignatureMatchesWithoutExecutingIt() throws {
        guard ProcessInfo.processInfo.environment["TRAFFIC_NATIVE_UI_TESTS"] == "1" else { throw XCTSkip("Optional read-only signature check on connected Mac.") }
        let executable = URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        guard FileManager.default.fileExists(atPath: executable.path) else { throw XCTSkip("Tailscale is optional.") }
        XCTAssertTrue(NetworkInventory.trustedTailscale(executable: executable))
    }
}
