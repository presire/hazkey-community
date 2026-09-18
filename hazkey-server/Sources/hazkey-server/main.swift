import Foundation

// loadZenzaiDevicesSafely()のバックエンドプローブが使用する隠し再実行モード
// 隔離子プロセスにて、GGML / Vulkanバックエンドをロードして終了する
//
// 異なるベンダーのVulkan ICD競合等でクラッシュしても、親プロセスはhazkey-serverの障害ではなくシグナルとして観測する
// 他の起動処理より先に判定する必要がある
if CommandLine.arguments.contains("--probe-backends") {
    runBackendProbeAndExit()
}

do {
    NSLog("Starting hazkey-server...")
    let server = HazkeyServer()

    try server.start()
} catch {
    NSLog("Failed to start server: \(error)")
    exit(1)
}
