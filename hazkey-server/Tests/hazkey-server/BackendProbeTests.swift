import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 実際のVulkan / GGMLバックエンドローダーの代わりに、/bin/shフィクスチャを使用して、backendProbe.swiftのクラッシュ隔離機構を検証する
/// これにより、GPUハードウェアやドライバ状態に依存せず、終了・シグナル・タイムアウトの分類ロジックを確認できる
final class BackendProbeTests: XCTestCase {
    private final class FailingLinkFileManager: FileManager, @unchecked Sendable {
        override func createSymbolicLink(at url: URL, withDestinationURL destURL: URL) throws {
            throw POSIXError(.EACCES)
        }
    }

    func testCPUBackendDirectoryIsPrivateUnpredictableAndCached() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["libggml-cpu-x64.so", "libggml-vulkan.so", "libggml-cuda.so"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let directory = try XCTUnwrap(cpuOnlyBackendDirectory(baseDirectory: root.path))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        XCTAssertEqual(cpuOnlyBackendDirectory(baseDirectory: root.path), directory)
        XCTAssertFalse(directory.hasSuffix("-\(getpid())"))
        var info = stat()
        XCTAssertEqual(lstat(directory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), ["libggml-cpu-x64.so"])
    }

    func testCPUBackendDirectoryFailsClosedOnSymlinkFailure() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("libggml-cpu-x64.so"))
        XCTAssertNil(cpuOnlyBackendDirectory(baseDirectory: root.path, fileManager: FailingLinkFileManager()))
    }

    // MARK: Vulkan環境変数の上書き判定

    func testVulkanEnvOverridePresentTrueForEachKnownVariable() {
        for variable in vulkanOverrideEnvironmentVariables {
            XCTAssertTrue(
                vulkanEnvOverridePresent(in: [variable: "anything"]),
                "\(variable) should be recognized as a Vulkan override")
        }
    }

    func testVulkanEnvOverridePresentFalseWithoutKnownVariables() {
        XCTAssertFalse(vulkanEnvOverridePresent(in: [:]))
        XCTAssertFalse(vulkanEnvOverridePresent(in: ["PATH": "/usr/bin", "HOME": "/home/x"]))
    }

    // MARK: バックエンドプローブの安全な実行

    func testProbeSuccessOnCleanExit() {
        let outcome = probeVulkanBackendsSafely(
            executablePath: "/bin/sh", arguments: ["-c", "exit 0"])
        XCTAssertEqual(outcome, .success)
    }

    func testProbeFailedExitOnNonZeroExit() {
        let outcome = probeVulkanBackendsSafely(
            executablePath: "/bin/sh", arguments: ["-c", "exit 3"])
        XCTAssertEqual(outcome, .failedExit(code: 3))
    }

    func testProbeCrashedOnSignal() {
        let outcome = probeVulkanBackendsSafely(
            executablePath: "/bin/sh", arguments: ["-c", "kill -ILL $$"])
        XCTAssertEqual(outcome, .crashed(signal: SIGILL))
    }

    func testProbeTimedOutWhenChildHangs() {
        let outcome = probeVulkanBackendsSafely(
            executablePath: "/bin/sh", arguments: ["-c", "sleep 30"], timeoutSeconds: 0.3)
        XCTAssertEqual(outcome, .timedOut)
    }

    func testProbeSpawnFailedOnMissingExecutable() {
        let outcome = probeVulkanBackendsSafely(executablePath: "/nonexistent/hazkey-probe-fixture")
        guard case .spawnFailed = outcome else {
            return XCTFail("expected .spawnFailed, got \(outcome)")
        }
    }

    func testProbeReapsTermResistantChildAfterKillGrace() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let start = ContinuousClock.now
        let outcome = probeVulkanBackendsSafely(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do :; done"],
            timeoutSeconds: 0.1)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(550))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testProbeQuickExitsDoNotLeaveChildrenOrDelayedWatchdogs() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        for _ in 0..<10 {
            XCTAssertEqual(probeVulkanBackendsSafely(
                executablePath: "/bin/sh",
                arguments: ["-c", "echo $$ > '\(pidFile.path)'; exit 0"], timeoutSeconds: 0.2), .success)
            let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
        }
    }

    func testProbeRejectsNulArgumentWithoutSpawning() {
        guard case .spawnFailed = probeVulkanBackendsSafely(
            executablePath: "/bin/sh", arguments: ["-c", "exit 0\0exit 1"]) else {
            return XCTFail("Expected argument validation failure")
        }
    }

    // MARK: 実行中バイナリのパス取得

    func testResolveSelfExecutablePathReturnsNonEmptyPath() {
        let path = resolveSelfExecutablePath()
        XCTAssertNotNil(path)
        XCTAssertFalse(path?.isEmpty ?? true)
    }

    // MARK: GPUフォールバックの有効判定

    func testGPUFallbackActiveForUnsafeOutcomes() {
        XCTAssertTrue(zenzaiGPUFallbackActive(.crashed(signal: SIGILL)))
        XCTAssertTrue(zenzaiGPUFallbackActive(.failedExit(code: 1)))
        XCTAssertTrue(zenzaiGPUFallbackActive(.timedOut))
        XCTAssertTrue(zenzaiGPUFallbackActive(.spawnFailed("reason")))
    }

    func testGPUFallbackInactiveForSafeOrUnhandledOutcomes() {
        XCTAssertFalse(zenzaiGPUFallbackActive(nil))
        XCTAssertFalse(zenzaiGPUFallbackActive(.success))
    }
}
