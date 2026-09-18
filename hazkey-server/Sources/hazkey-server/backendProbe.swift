import Foundation
import Glibc
import KanaKanjiConverterModule

/// ユーザがVulkan Loaderに使用するドライバを明示したことを表す環境変数
/// いずれかが存在する場合、hazkey-serverは独自のprobeにより、この選択を上書きしてはならない
/// これらの優先順位は、Vulkan Loader自身が解決するため、ここでの並び順は意味を持たない
let vulkanOverrideEnvironmentVariables = [
    "VK_DRIVER_FILES",
    "VK_ICD_FILENAMES",
    "VK_ADD_DRIVER_FILES",
    "VK_LOADER_DRIVERS_SELECT",
    "VK_LOADER_DRIVERS_DISABLE",
]

/// GGML/Vulkanバックエンドのロードを試す隔離子プロセスの終了結果
/// 子プロセスがSIGILL / SIGSEGVでクラッシュすれば、実サーバやユーザのFcitx5 / IBusセッションを停止させずに、
/// 現在のドライバー組み合わせが安全でないことを検出できる
enum BackendProbeOutcome: Equatable {
    case success
    case crashed(signal: Int32)
    case failedExit(code: Int32)
    case timedOut
    case spawnFailed(String)
}

/// プローブが現在のVulkanドライバ組み合わせを安全でないと判定したため、推論をCPU専用で実行する場合にTrueを返す
/// "spawnFailed"と"nil"はフォールバックではなく、プローブ導入前と同様にバックエンドを直接ロードする
/// 設定GUIで無言の性能低下を警告できるよう、"CurrentConfig.zenzai_gpu_probe_fallback"に公開する
func zenzaiGPUFallbackActive(_ outcome: BackendProbeOutcome?) -> Bool {
    switch outcome {
    case .crashed, .failedExit, .timedOut:
        return true
    case .success, .spawnFailed, nil:
        return false
    }
}

/// ユーザがシェルの環境変数 / "$XDG_CONFIG_HOME/hazkey/env"ファイルでVulkanドライバを既に選択している場合にTrueを返す
/// その場合、選択を信頼して以降の安全性プローブを完全に省略し、ユーザ指定どおりに適用する
func vulkanEnvOverridePresent(in environment: [String: String]) -> Bool {
    vulkanOverrideEnvironmentVariables.contains { environment[$0] != nil }
}

/// "/proc/self/exe"ファイルを使用して、実行中バイナリの絶対パスを取得する (Linux専用)
func resolveSelfExecutablePath() -> String? {
    let capacity = 4096
    let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: capacity)
    defer { buffer.deallocate() }
    let length = readlink("/proc/self/exe", buffer, capacity - 1)
    guard length > 0 else { return nil }
    buffer[length] = 0
    return String(cString: buffer)
}

/// "executablePath arguments..."を起動して終了を待機し、終了状態を分類する
/// 実際の"--probe-backends"再実行に加え、Vulkanに触れずにクラッシュ・タイムアウト・非ゼロ終了を検証するため、
/// 実行ファイルと引数を注入したユニットテストでも利用する
func probeVulkanBackendsSafely(
    executablePath: String? = nil,
    arguments: [String] = ["--probe-backends"],
    timeoutSeconds: TimeInterval = 5.0
) -> BackendProbeOutcome {
    guard let exePath = executablePath ?? resolveSelfExecutablePath() else {
        return .spawnFailed("failed to resolve current executable path")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: exePath)
    process.arguments = arguments
    // プローブは実サーバと同じ環境を観測しなければならないため、
    // Vulkan関連の環境変数を追加・削除せずにそのまま継承する
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    }
    catch {
        return .spawnFailed("\(error)")
    }

    let watchdog = Thread {
        Thread.sleep(forTimeInterval: timeoutSeconds)
        guard process.isRunning else { return }
        process.terminate()  // SIGTERMシグナルを送信して、強制終了へ進む
        Thread.sleep(forTimeInterval: 0.5)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    watchdog.start()

    // 子プロセスが終了するか上記ウォッチドッグに停止されるまで待機する
    // ドライバクラッシュでも正常終了と同様に子プロセスのfdが閉じるため、SIGILL / SIGSEGVでもここは正しく待機解除される
    process.waitUntilExit()

    if process.terminationReason == .uncaughtSignal {
        let signal = process.terminationStatus
        // 実際のドライバクラッシュは、
        // SIGILL / SIGSEGV / SIGABRT / SIGBUS / SIGFPEを発生させ、子プロセス自身がSIGTERM / SIGKILLを送信することはない
        // 後者は、上記ウォッチドッグ経由でのみ届くため、この関数とウォッチドッグスレッド間で共有可変状態を持たずにタイムアウトとして判別できる
        if signal == SIGTERM || signal == SIGKILL {
            return .timedOut
        }
        return .crashed(signal: signal)
    }

    if process.terminationStatus != 0 {
        return .failedExit(code: process.terminationStatus)
    }
    return .success
}

/// baseDirectory内のバックエンドプラグインからVulkan用だけを除外して、一時ディレクトリにシンボリックリンクを作成する
/// 対象名は、GGMLが走査する"libggml-vulkan-*.so" / "libggml-vulkan.so"と一致させる
/// (ggml-backend-reg.cppのggml_backend_load_best()を参照)
///
/// GGMLは、ディレクトリ内の全候補をdlopenして呼び出すため、
/// プローブ子プロセスが危険と判定した後にVulkanを再ロードさせない方法は、走査対象から隠すことだけである
/// GGML側に個別の名前を除外するAPIはない
///
/// ディレクトリを読めない場合、または、Vulkan以外のエントリがない場合はnilを返す
func cpuOnlyBackendDirectory(
    baseDirectory: String? = nil,
    fileManager: FileManager = .default
) -> String? {
    let sourceDirectory =
        baseDirectory
        ?? ProcessInfo.processInfo.environment["GGML_BACKEND_DIR"]
        ?? (systemLibraryPath + "/libllama/backends/")
    guard let entries = try? fileManager.contentsOfDirectory(atPath: sourceDirectory) else {
        return nil
    }
    let keptEntries = entries.filter {
        !($0.hasPrefix("libggml-vulkan-") || $0 == "libggml-vulkan.so")
    }
    guard !keptEntries.isEmpty else { return nil }

    let stagingDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("hazkey-cpu-only-backends-\(ProcessInfo.processInfo.processIdentifier)")
    try? fileManager.removeItem(at: stagingDirectory)
    guard (try? fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)) != nil else {
        return nil
    }

    let sourceURL = URL(fileURLWithPath: sourceDirectory, isDirectory: true)
    for entry in keptEntries {
        try? fileManager.createSymbolicLink(
            at: stagingDirectory.appendingPathComponent(entry),
            withDestinationURL: sourceURL.appendingPathComponent(entry)
        )
    }
    return stagingDirectory.path
}

/// 危険と判定されたドライバスタックに対する第2段階のフォールバック
/// cpuOnlyBackendDirectory()が作成したVulkanを含まないディレクトリからバックエンドを再ロードして、
/// 他のGPUプラグインが存在する場合も考慮してCPUデバイスだけを残す
/// ディレクトリを作成できない場合のみ空配列を返して、AIモデルを完全に無効化する
func cpuOnlyZenzaiDevices() -> [GGMLBackendDevice] {
    guard let directory = cpuOnlyBackendDirectory() else {
        NSLog("[BackendProbe] Could not build a Vulkan-free backend directory; disabling Zenzai for this session.")
        return []
    }
    return getZenzaiDevices(backendDirectoryOverride: directory).filter { $0.type == .cpu }
}

/// 隠し"--probe-backends"モードの入口
/// 通常起動と同じ方法で、GGMLバックエンドをロードしてから正常終了する
/// 異なるベンダーのVulkan ICDが競合する等、ドライバースタックが危険な場合は、
/// 実サーバではなく、このプロセスがクラッシュし、親のloadZenzaiDevicesSafely()がprobeVulkanBackendsSafely()で検出する
func runBackendProbeAndExit() -> Never {
    _ = getZenzaiDevices()
    exit(0)
}

/// 利用可能なZenzaiバックエンドデバイスをロードする
/// getZenzaiDevices()単体では防げないドライバクラッシュから実サーバを保護する
///
/// - ユーザがVulkan環境変数を明示指定している場合は、そのまま信頼してプローブを省略する ("probeOutcome"はnil)
/// - それ以外では、隔離された"--probe-backends"子プロセスが先に同じバックエンドロードを行う
///   クラッシュ・タイムアウト・非ゼロ終了時は、 実サーバで同じクラッシュを起こす代わりに、cpuOnlyZenzaiDevices()へフォールバックする
/// - 成功時は従来どおり実プロセス内でバックエンドをロードする
///   実際の推論に必要なGGMLバックエンド登録はプロセス間で共有できないためである
///
/// [Hazkey 設定]画面でCPU専用フォールバックを通知できるよう、ロードしたデバイスとプローブ結果をまとめて返す
/// (zenzaiGPUFallbackActive(_:)を参照)
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
        NSLog(
            "[BackendProbe] Backend probe process was killed by signal \(signal) "
                + "(likely an unsafe Vulkan driver combination). "
                + "Disabling GPU acceleration for this session; CPU inference only."
        )
        return (cpuOnlyZenzaiDevices(), outcome)
    case .failedExit(let code):
        NSLog(
            "[BackendProbe] Backend probe exited with status \(code). "
                + "Disabling GPU acceleration for this session; CPU inference only."
        )
        return (cpuOnlyZenzaiDevices(), outcome)
    case .timedOut:
        NSLog(
            "[BackendProbe] Backend probe timed out. "
                + "Disabling GPU acceleration for this session; CPU inference only."
        )
        return (cpuOnlyZenzaiDevices(), outcome)
    case .spawnFailed(let reason):
        NSLog(
            "[BackendProbe] Failed to spawn backend probe (\(reason)); "
                + "loading backends directly without the safety check."
        )
        return (getZenzaiDevices(), outcome)
    }
}
