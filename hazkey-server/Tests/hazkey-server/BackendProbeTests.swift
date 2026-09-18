import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 実際のVulkan / GGMLバックエンドローダーの代わりに、/bin/shフィクスチャを使用して、backendProbe.swiftのクラッシュ隔離機構を検証する
/// これにより、GPUハードウェアやドライバ状態に依存せず、終了・シグナル・タイムアウトの分類ロジックを確認できる
final class BackendProbeTests: XCTestCase {

    // MARK: - Vulkan環境変数の上書き判定

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

    // MARK: - バックエンドプローブの安全な実行

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

    // MARK: - 実行中バイナリのパス取得

    func testResolveSelfExecutablePathReturnsNonEmptyPath() {
        let path = resolveSelfExecutablePath()
        XCTAssertNotNil(path)
        XCTAssertFalse(path?.isEmpty ?? true)
    }

    // MARK: - GPUフォールバックの有効判定

    func testGPUFallbackActiveForUnsafeOutcomes() {
        XCTAssertTrue(zenzaiGPUFallbackActive(.crashed(signal: SIGILL)))
        XCTAssertTrue(zenzaiGPUFallbackActive(.failedExit(code: 1)))
        XCTAssertTrue(zenzaiGPUFallbackActive(.timedOut))
    }

    func testGPUFallbackInactiveForSafeOrUnhandledOutcomes() {
        XCTAssertFalse(zenzaiGPUFallbackActive(nil))
        XCTAssertFalse(zenzaiGPUFallbackActive(.success))
        XCTAssertFalse(zenzaiGPUFallbackActive(.spawnFailed("reason")))
    }
}
