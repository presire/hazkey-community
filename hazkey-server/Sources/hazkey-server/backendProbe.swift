import Foundation
import Glibc
import CHazkeyLinux
import KanaKanjiConverterModule

/// ユーザがVulkanドライバの選択を明示したことを示す環境変数の一覧
///
/// [VK_DRIVER_FILES]、[VK_ICD_FILENAMES]、[VK_ADD_DRIVER_FILES]、[VK_LOADER_DRIVERS_SELECT]、[VK_LOADER_DRIVERS_DISABLE]のいずれかが設定されている場合、
/// hazkey-serverは独自のプローブでその選択を上書きしない
///
/// 優先順位はVulkan Loaderが解決するため、ここでの並び順に意味はない
let vulkanOverrideEnvironmentVariables = [
    "VK_DRIVER_FILES",
    "VK_ICD_FILENAMES",
    "VK_ADD_DRIVER_FILES",
    "VK_LOADER_DRIVERS_SELECT",
    "VK_LOADER_DRIVERS_DISABLE",
]

/// GGML/Vulkanバックエンドの読み込みを試す隔離子プロセスの終了結果
///
/// 子プロセスが異常なドライバの組み合わせでクラッシュしても、実サーバやユーザのFcitx5 / IBusセッションを停止させずに安全でない組み合わせを検出できる
enum BackendProbeOutcome: Equatable {
    /// 正常終了したことを示す
    case success
    /// 子プロセスがシグナルで強制終了したことを示す
    case crashed(signal: Int32)
    /// 子プロセスが非ゼロの終了コードで終了したことを示す
    case failedExit(code: Int32)
    /// 子プロセスが制限時間内に終了しなかったことを示す
    case timedOut
    /// 子プロセスを起動できなかったことを示す
    case spawnFailed(String)
}

/// プローブが現在のVulkanドライバの組み合わせを安全でないと判定したため推論をCPU専用で実行するかどうかを返す
///
/// [crashed]、[failedExit]、[timedOut]の場合に真を返す
///
/// プローブを起動できない場合も安全性を確認できないためフォールバックする
///
/// CPU専用への切り替えは[zenzai_gpu_probe_fallback]として公開し、設定GUIが無言の性能低下を警告できるようにする
///
/// - Parameter outcome: 判定対象のプローブ結果 (nilの場合はプローブ未実行を表す)
/// - Returns: CPU専用で実行する場合に真を返す
func zenzaiGPUFallbackActive(_ outcome: BackendProbeOutcome?) -> Bool {
    switch outcome {
    case .crashed, .failedExit, .timedOut, .spawnFailed:
        return true
    case .success, nil:
        return false
    }
}

/// ユーザがVulkanドライバを既に選択しているかどうかを返す
///
/// シェル環境または[$XDG_CONFIG_HOME/hazkey-community/env]ファイルでの指定を検出する
///
/// 真の場合はその選択を信頼し、以降の安全性プローブを完全に省略する
///
/// - Parameter environment: 検査対象の環境変数
/// - Returns: ユーザによる明示指定がある場合に真を返す
func vulkanEnvOverridePresent(in environment: [String: String]) -> Bool {
    vulkanOverrideEnvironmentVariables.contains { environment[$0] != nil }
}

/// 実行中バイナリの絶対パスを取得する
///
/// [/proc/self/exe]を読み取って解決する (Linux専用)
///
/// - Returns: 取得に成功した場合は絶対パス、失敗した場合はnilを返す
func resolveSelfExecutablePath() -> String? {
    let capacity = 4096
    let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: capacity)
    defer { buffer.deallocate() }
    let length = readlink("/proc/self/exe", buffer, capacity - 1)
    guard length > 0 else { return nil }
    buffer[length] = 0
    return String(cString: buffer)
}

/// 実行ファイルを指定引数で起動して終了状態を分類する
///
/// 実サーバと同じ環境を観測しなければならないため、Vulkan関連の環境変数はそのまま継承する
///
/// 既定引数は[--probe-backends]、既定の制限時間は5.0秒である
///
/// waitpidを期限までポーリングし、期限後は[SIGTERM]、0.5秒後に[SIGKILL]を送って回収する
///
/// 未捕捉シグナルによる終了のうち[SIGTERM] / [SIGKILL]は[timedOut]とし、
/// それ以外 ([SIGILL] / [SIGSEGV] / [SIGABRT] / [SIGBUS] / [SIGFPE]) は[crashed]とする
///
/// 非ゼロ終了は[failedExit]とする
///
/// 通常起動の[--probe-backends]再実行に加え、実行ファイルと引数を注入した単体試験でも利用する
///
/// - Parameters:
///   - executablePath: 起動する実行ファイル (nilの場合は実行中のバイナリを解決する)
///   - arguments: 子プロセスへ渡す引数
///   - timeoutSeconds: 子プロセスの終了を待つ制限時間(秒)
/// - Returns: 分類したプローブ結果
func probeVulkanBackendsSafely(
    executablePath: String? = nil,
    arguments: [String] = ["--probe-backends"],
    timeoutSeconds: TimeInterval = 5.0
) -> BackendProbeOutcome {
    let childPID: pid_t
    do {
        childPID = try spawnProbeChild(path: executablePath ?? "/proc/self/exe", arguments: arguments)
    } catch {
        return .spawnFailed("\(error)")
    }
    var status: Int32 = 0
    func waitUntil(_ deadline: ContinuousClock.Instant) throws -> Bool {
        while true {
            let result = waitpid(childPID, &status, WNOHANG)
            if result == childPID { return true }
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if ContinuousClock.now >= deadline { return false }
            usleep(10_000)
        }
    }
    do {
        let seconds = timeoutSeconds.isFinite ? max(timeoutSeconds, 0) : 5.0
        if try !waitUntil(ContinuousClock.now.advanced(by: .seconds(seconds))) {
            // 未回収の子のPIDは再利用されない。回収後は一切シグナルを送らない
            kill(childPID, SIGTERM)
            if try !waitUntil(ContinuousClock.now.advanced(by: .milliseconds(500))) {
                kill(childPID, SIGKILL)
                while waitpid(childPID, &status, 0) < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return .timedOut
        }
    } catch {
        return .spawnFailed("waitpid failed: \(error)")
    }
    let signal = hazkey_wait_signal(status)
    if signal == SIGTERM || signal == SIGKILL { return .timedOut }
    if signal != 0 { return .crashed(signal: signal) }
    let code = hazkey_wait_exit_code(status)
    if code != 0 { return .failedExit(code: code) }
    return .success
}

/// Foundation.Processの終了通知用UDPソケットを作らずに、環境と標準入力を継承して起動する
func spawnProbeChild(path: String, arguments: [String]) throws -> pid_t {
    let strings = [path] + arguments
    guard strings.allSatisfy({ !$0.utf8.contains(0) }) else { throw POSIXError(.EINVAL) }
    var argv: [UnsafeMutablePointer<CChar>?] = []
    defer { for pointer in argv { free(pointer) } }
    for string in strings {
        guard let pointer = strdup(string) else { throw POSIXError(.ENOMEM) }
        argv.append(pointer)
    }
    argv.append(nil)
    var pid: pid_t = 0
    let error = hazkey_spawn_probe(path, &argv, &pid)
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    return pid
}

private final class CPUBackendDirectoryCache: @unchecked Sendable {
    static let shared = CPUBackendDirectoryCache()
    let lock = NSLock()
    var paths: [String: String] = [:]

    private init() {
        atexit { CPUBackendDirectoryCache.shared.removeAll() }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for path in paths.values { try? FileManager.default.removeItem(atPath: path) }
        paths.removeAll()
    }
}

/// CPUライブラリだけを私有の一時ディレクトリへリンクし、失敗時は読み込みを禁止する
func cpuOnlyBackendDirectory(
    baseDirectory: String? = nil,
    fileManager: FileManager = .default
) -> String? {
    let sourceDirectory =
        baseDirectory
        ?? ProcessInfo.processInfo.environment["GGML_BACKEND_DIR"]
        ?? (systemLibraryPath + "/libllama/backends/")
    let cache = CPUBackendDirectoryCache.shared
    cache.lock.lock()
    defer { cache.lock.unlock() }
    let cacheKey = sourceDirectory + "\n" + fileManager.temporaryDirectory.path
    if let cached = cache.paths[cacheKey] { return cached }
    guard let entries = try? fileManager.contentsOfDirectory(atPath: sourceDirectory) else {
        NSLog("[BackendProbe] Cannot read CPU backend source; disabling Zenzai.")
        return nil
    }
    let keptEntries = entries.filter {
        ($0.hasPrefix("libggml-cpu-") && $0.hasSuffix(".so")) || $0 == "libggml-cpu.so"
    }
    guard !keptEntries.isEmpty else {
        NSLog("[BackendProbe] No CPU backend libraries found; disabling Zenzai.")
        return nil
    }

    var template = Array(fileManager.temporaryDirectory
        .appendingPathComponent("hazkey-community-cpu-only-backends-XXXXXX").path.utf8CString)
    guard let created = mkdtemp(&template) else {
        hazkeyLog("[BackendProbe] mkdtemp failed: \(errno); disabling Zenzai.")
        return nil
    }
    let stagingDirectory = URL(fileURLWithPath: String(cString: created), isDirectory: true)

    let sourceURL = URL(fileURLWithPath: sourceDirectory, isDirectory: true)
    do {
        for entry in keptEntries {
            try fileManager.createSymbolicLink(
                at: stagingDirectory.appendingPathComponent(entry),
                withDestinationURL: sourceURL.appendingPathComponent(entry))
        }
    } catch {
        hazkeyLog("[BackendProbe] Failed to stage CPU backends: \(error); disabling Zenzai.")
        try? fileManager.removeItem(at: stagingDirectory)
        return nil
    }
    cache.paths[cacheKey] = stagingDirectory.path
    return stagingDirectory.path
}

/// 第2段階のフォールバックとしてVulkanなしのCPUデバイスだけを読み込む
///
/// cpuOnlyBackendDirectory()が作成したVulkanなしのディレクトリからバックエンドを再読み込みし、他のGPUプラグインが存在する場合も考慮してCPUデバイスだけを残す
///
/// ディレクトリを作成できない場合のみ空配列を返してモデルを完全に無効化する
///
/// GGMLは環境変数GGML_BACKEND_PATHが指す追加バックエンドも読み込むため、このセッションでは環境変数を削除したままにする (CPU専用の判定はセッション単位)
///
/// 削除後に元の値を書き戻さないのは、setenvが環境変数の配列を再確保し、他のスレッドのgetenvが解放済みの配列を読み得るためである
///
/// - Returns: 利用可能なCPUデバイス、復旧できない場合は空配列を返す
func cpuOnlyZenzaiDevices() -> [GGMLBackendDevice] {
    guard let directory = cpuOnlyBackendDirectory() else {
        NSLog("[BackendProbe] Could not build a Vulkan-free backend directory; disabling Zenzai for this session.")
        return []
    }
    if getenv("GGML_BACKEND_PATH") != nil {
        unsetenv("GGML_BACKEND_PATH")
    }
    defer { CPUBackendDirectoryCache.shared.removeAll() }
    return getZenzaiDevices(backendDirectoryOverride: directory).filter { $0.type == .cpu }
}

/// 隠し[--probe-backends]モードの入口として実行して終了する
///
/// 通常起動と同じ方法でGGMLバックエンドを読み込んでから、終了コード0で終了する
///
/// ドライバスタックが安全でない場合は、実サーバではなくこのプロセスがクラッシュし、親はprobeVulkanBackendsSafely()で検出する
///
/// - Note: 正常系でも終了コード0で終了するため戻らない
func runBackendProbeAndExit() -> Never {
    _ = getZenzaiDevices()
    exit(0)
}

/// 利用可能なZenzaiバックエンドデバイスを実サーバのクラッシュから保護しながら読み込む
///
/// getZenzaiDevices()単体では防げないドライバクラッシュから実サーバを保護する
///
/// ユーザがVulkan環境変数を明示指定している場合は、その指定を信頼してプローブを省略して、probeOutcomeはnilになる
///
/// それ以外の場合は隔離した[--probe-backends]子プロセスが同じバックエンド読み込みを先行して試す
///
/// 子プロセスのクラッシュ、タイムアウト、非ゼロ終了時は実サーバで同じクラッシュを起こす代わりにcpuOnlyZenzaiDevices()へフォールバックする
///
/// 成功時は実際の推論に必要なGGMLバックエンド登録をプロセス間で共有できないため、実プロセス内でバックエンドを読み込む
///
/// 読み込んだデバイスとプローブ結果をまとめて返すことで、[Hazkey Community設定]画面がCPU専用フォールバックを通知できる
///
/// - Returns: 読み込んだデバイスとプローブ結果の組
func loadZenzaiDevicesSafely() -> (devices: [GGMLBackendDevice], probeOutcome: BackendProbeOutcome?) {
    let environment = ProcessInfo.processInfo.environment
    if vulkanEnvOverridePresent(in: environment) {
        NSLog("[BackendProbe] Vulkan environment override detected; skipping backend safety probe.")
        return (getZenzaiDevices(), nil)
    }

    let outcome = probeVulkanBackendsSafely()
    switch outcome {
    case .success:
        NSLog("[BackendProbe] Backend probe succeeded; loading GPU backends normally.")
        return (getZenzaiDevices(), outcome)
    case .crashed(let signal):
        hazkeyLog(
            "[BackendProbe] Backend probe process was killed by signal \(signal) "
                + "(likely an unsafe Vulkan driver combination). "
                + "Disabling GPU acceleration for this session; CPU inference only."
        )
        return (cpuOnlyZenzaiDevices(), outcome)
    case .failedExit(let code):
        hazkeyLog(
            "[BackendProbe] Backend probe exited with status \(code). "
                + "Disabling GPU acceleration for this session; CPU inference only."
        )
        return (cpuOnlyZenzaiDevices(), outcome)
    case .timedOut:
        hazkeyLog(
            "[BackendProbe] Backend probe timed out. "
                + "Disabling GPU acceleration for this session; CPU inference only."
        )
        return (cpuOnlyZenzaiDevices(), outcome)
    case .spawnFailed(let reason):
        hazkeyLog(
            "[BackendProbe] Failed to spawn backend probe (\(reason)); "
                + "using CPU backends only."
        )
        return (cpuOnlyZenzaiDevices(), outcome)
    }
}
